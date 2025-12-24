"""
Lambda #1: Manifest Builder
===========================

Receives SQS messages for new NDJSON files, batches them into 1GB groups,
and creates manifest files for Glue Streaming to process.

Author: Data Engineering Team
Version: 1.1.0 (Updated with code review fixes)

Changes in 1.1.0:
- Added DynamoDB pagination for large result sets
- Moved hardcoded constants to environment variables
- Added distributed locking to prevent race conditions
- Improved error handling and logging
"""

import json
import os
import boto3
import hashlib
import time
import re
from datetime import datetime, timedelta
from decimal import Decimal
from typing import List, Dict, Tuple, Optional
import logging

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS Clients (reused across invocations for Lambda warm starts)
s3_client = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')
glue_client = boto3.client('glue')

# Environment Variables
MANIFEST_BUCKET = os.environ['MANIFEST_BUCKET']
TRACKING_TABLE = os.environ['TRACKING_TABLE']
GLUE_JOB_NAME = os.environ.get('GLUE_JOB_NAME', '')
MAX_BATCH_SIZE_GB = float(os.environ.get('MAX_BATCH_SIZE_GB', '1.0'))
QUARANTINE_BUCKET = os.environ.get('QUARANTINE_BUCKET', '')

# Configurable validation parameters (moved from hardcoded constants)
EXPECTED_FILE_SIZE_MB = float(os.environ.get('EXPECTED_FILE_SIZE_MB', '3.5'))
SIZE_TOLERANCE_PERCENT = float(os.environ.get('SIZE_TOLERANCE_PERCENT', '10'))

# Lock configuration for distributed locking
LOCK_TABLE = os.environ.get('LOCK_TABLE', TRACKING_TABLE)  # Can use same table or separate
LOCK_TTL_SECONDS = int(os.environ.get('LOCK_TTL_SECONDS', '300'))  # 5 minutes

# DynamoDB table
table = dynamodb.Table(TRACKING_TABLE)


class DistributedLock:
    """
    Simple distributed lock using DynamoDB conditional writes.
    Prevents race conditions when multiple Lambda invocations process the same date prefix.
    """
    
    def __init__(self, lock_table: str, lock_key: str, ttl_seconds: int = 300):
        self.table = dynamodb.Table(lock_table)
        self.lock_key = lock_key
        self.ttl_seconds = ttl_seconds
        self.lock_id = f"{os.environ.get('AWS_LAMBDA_LOG_STREAM_NAME', 'local')}_{int(time.time() * 1000)}"
        self.acquired = False
    
    def acquire(self) -> bool:
        """Attempt to acquire the lock. Returns True if successful."""
        try:
            ttl = int(time.time()) + self.ttl_seconds
            self.table.put_item(
                Item={
                    'date_prefix': f'LOCK#{self.lock_key}',
                    'file_name': 'LOCK',
                    'lock_id': self.lock_id,
                    'ttl': ttl,
                    'created_at': datetime.utcnow().isoformat()
                },
                ConditionExpression='attribute_not_exists(date_prefix) OR #ttl < :now',
                ExpressionAttributeNames={'#ttl': 'ttl'},
                ExpressionAttributeValues={':now': int(time.time())}
            )
            self.acquired = True
            logger.info(f"Lock acquired for {self.lock_key}")
            return True
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            logger.info(f"Lock already held for {self.lock_key}")
            return False
        except Exception as e:
            logger.error(f"Error acquiring lock: {str(e)}")
            return False
    
    def release(self):
        """Release the lock if we hold it."""
        if not self.acquired:
            return
        
        try:
            self.table.delete_item(
                Key={
                    'date_prefix': f'LOCK#{self.lock_key}',
                    'file_name': 'LOCK'
                },
                ConditionExpression='lock_id = :lock_id',
                ExpressionAttributeValues={':lock_id': self.lock_id}
            )
            logger.info(f"Lock released for {self.lock_key}")
        except Exception as e:
            logger.warning(f"Error releasing lock (may have expired): {str(e)}")
        finally:
            self.acquired = False
    
    def __enter__(self):
        return self.acquire()
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.release()
        return False


class ManifestBuilder:
    """Builds manifest files for batches of NDJSON files."""
    logger.info("----------------- ManifestBuilder --------------")
    
    def __init__(self):
        self.max_batch_size_bytes = int(MAX_BATCH_SIZE_GB * 1024 * 1024 * 1024)
        self.files_per_batch = int(self.max_batch_size_bytes / (EXPECTED_FILE_SIZE_MB * 1024 * 1024))
        logger.info(f"Initialized: max_batch={MAX_BATCH_SIZE_GB}GB, "
                   f"expected_file_size={EXPECTED_FILE_SIZE_MB}MB, "
                   f"tolerance={SIZE_TOLERANCE_PERCENT}%, "
                   f"files_per_batch={self.files_per_batch}")
    
    def process_sqs_messages(self, records: List[Dict]) -> Dict:
        logger.info("----------------- process_sqs_messages --------------")
        """
        Process SQS messages containing S3 events.
        
        Args:
            records: SQS records from event
            
        Returns:
            Processing statistics
        """
        stats = {
            'total_messages': len(records),
            'files_processed': 0,
            'files_quarantined': 0,
            'manifests_created': 0,
            'errors': []
        }
        
        pending_files = []
        
        # Extract file information from SQS messages
        for record in records:
            try:
                # Parse S3 event from SQS message
                message_body = json.loads(record['body'])
                logger.info(f"Processing message: {message_body}")
                
                # Handle different message formats
                if 'Records' in message_body:
                    # SNS or direct S3 event
                    s3_event = message_body['Records'][0]
                else:
                    s3_event = message_body
                
                bucket = s3_event['s3']['bucket']['name']
                key = s3_event['s3']['object']['key']
                size = s3_event['s3']['object'].get('size', 0)
                size = int(size) if size else 0
                logger.info(f"Processing file: {key}")
                logger.info(f"File size: {size} bytes")
                logger.info(f"Bucket: {bucket}")
                
                # Validate file
                file_info = self._validate_and_extract_info(bucket, key, size)
                logger.info(f"File info: {file_info}")
                
                if file_info['valid']:
                    pending_files.append(file_info)
                    stats['files_processed'] += 1
                else:
                    self._quarantine_file(file_info, file_info.get('error', 'Validation failed'))
                    stats['files_quarantined'] += 1
                    
            except Exception as e:
                error_msg = f"Error processing record: {str(e)}"
                logger.error(error_msg)
                stats['errors'].append(error_msg)
        
        # Track files in DynamoDB
        self._track_files(pending_files)
        
        # Check if we should create manifests
        date_groups = self._group_by_date(pending_files)
        
        for date_prefix, files in date_groups.items():
            manifests_created = self._create_manifests_if_ready(date_prefix, files)
            stats['manifests_created'] += manifests_created
        
        return stats
    
    def _validate_and_extract_info(
        self,
        bucket: str,
        key: str,
        size: int
    ) -> Dict:
        logger.info("----------------- _validate_and_extract_info --------------")
        """
        Validate file and extract information.
        
        Args:
            bucket: S3 bucket name
            key: S3 object key
            size: File size in bytes
            
        Returns:
            File information dictionary
        """
        filename = key.split('/')[-1]
        size_mb = size / (1024 * 1024)
        size_mb = round(size_mb, 2)
        logger.info(f"Processing file: {filename}, size: {size_mb}MB")
        logger.info(f"filename: {filename}")

        
        # Extract date prefix (yyyy-mm-dd)
        date_match = re.match(r'(\d{4}-\d{2}-\d{2})-', filename)
        date_prefix = date_match.group(1) if date_match else None
        
        # Validation checks
        valid = True
        error = None
        
        # Check file extension
        if not filename.endswith('.ndjson'):
            valid = False
            error = f"Invalid file extension: {filename}"
        
        # Check date prefix
        elif not date_prefix:
            valid = False
            error = f"Invalid filename format (expected yyyy-mm-dd-*): {filename}"
        
        # Check file size (using configurable tolerance)
        elif size_mb < EXPECTED_FILE_SIZE_MB * (1 - SIZE_TOLERANCE_PERCENT/100) or \
             size_mb > EXPECTED_FILE_SIZE_MB * (1 + SIZE_TOLERANCE_PERCENT/100):
            valid = False
            error = f"Unexpected file size: {size_mb:.2f}MB (expected ~{EXPECTED_FILE_SIZE_MB}MB ±{SIZE_TOLERANCE_PERCENT}%)"
        
        return {
            'bucket': bucket,
            'key': key,
            'filename': filename,
            'size_bytes': size,
            'size_mb': size_mb,
            'date_prefix': date_prefix,
            's3_path': f's3://{bucket}/{key}',
            'valid': valid,
            'error': error,
            'timestamp': datetime.utcnow().isoformat()
        }
    
    def _track_files(self, files: List[Dict]):
        logger.info("----------------- _track_files --------------")
        """Track files in DynamoDB."""
        ttl = int((datetime.utcnow() + timedelta(days=7)).timestamp())
        
        for file_info in files:
            logger.info(f"Tracking filename: {file_info['filename']}")
            logger.info(f"File info: {file_info}")
            logger.info(f"File size: {file_info['size_mb']}MB")
            logger.info(f"File date: {file_info['date_prefix']}")
            logger.info(f"File path: {file_info['s3_path']}")


            try:
                table.put_item(
                    Item={
                        'date_prefix': file_info['date_prefix'],
                        'file_name': file_info['filename'],
                        'file_path': file_info['s3_path'],
                        'file_size_mb': Decimal(str(round(file_info['size_mb'], 4))),
                        'status': 'pending',
                        'created_at': file_info['timestamp'],
                        'ttl': ttl
                    }
                )
            except Exception as e:
                logger.error(f"Error tracking file {file_info['filename']}: {str(e)}")
    
    def _group_by_date(self, files: List[Dict]) -> Dict[str, List[Dict]]:
        logger.info("----------------- _group_by_date --------------")
        """Group files by date prefix."""
        groups = {}
        for file_info in files:
            date_prefix = file_info['date_prefix']
            if date_prefix not in groups:
                groups[date_prefix] = []
            groups[date_prefix].append(file_info)
        return groups
    
    def _create_manifests_if_ready(
        self,
        date_prefix: str,
        new_files: List[Dict]
    ) -> int:
        logger.info("----------------- _create_manifests_if_ready --------------")
        """
        Create manifest files if batch is ready.
        Uses distributed locking to prevent race conditions.
        
        Args:
            date_prefix: Date prefix (yyyy-mm-dd)
            new_files: Newly added files
            
        Returns:
            Number of manifests created
        """
        # Acquire lock for this date prefix to prevent race conditions
        lock = DistributedLock(LOCK_TABLE, date_prefix, LOCK_TTL_SECONDS)
        
        if not lock.acquire():
            logger.info(f"Could not acquire lock for {date_prefix}, skipping manifest creation")
            return 0
        
        try:
            # Get all pending files for this date (with pagination)
            pending_files = self._get_pending_files(date_prefix)
            
            # Deduplicate new files that might already be tracked
            existing_filenames = {f['filename'] for f in pending_files}
            logger.info(f"Date {date_prefix}: {existing_filenames} existing files")

            unique_new_files = [f for f in new_files if f['filename'] not in existing_filenames]
            logger.info(f"Date {date_prefix}: {unique_new_files} new files")
            all_files = pending_files + unique_new_files
            all_files.sort(key=lambda x: x['filename'])
            all_files = list({f['filename']: f for f in all_files}.values())    
            all_files.sort(key=lambda x: x['filename'])
            logger.info(f"Date {date_prefix}: {all_files} all files")
            
            logger.info(f"Date {date_prefix}: {len(all_files)} pending files "
                       f"({len(pending_files)} existing + {len(unique_new_files)} new)")
            
            # Calculate total size
            total_size_bytes = sum(f['size_bytes'] for f in all_files)
            
            # Check if we should create manifests
            if total_size_bytes < self.max_batch_size_bytes:
                logger.info(f"Not enough data yet: {total_size_bytes / (1024**3):.2f}GB "
                           f"(need {MAX_BATCH_SIZE_GB}GB)")
                return 0
            
            # Create batches
            batches = self._create_batches(all_files)
            logger.info(f"Date {date_prefix}: {batches} batches created")
            
            # Create manifest for each batch
            manifests_created = 0
            for batch_idx, batch_files in enumerate(batches, 1):
                manifest_path = self._create_manifest(date_prefix, batch_idx, batch_files)
                if manifest_path:
                    manifests_created += 1
                    # Update file status
                    self._update_file_status(batch_files, 'manifested', manifest_path)
            
            return manifests_created
            
        finally:
            lock.release()
    
    def _get_pending_files(self, date_prefix: str) -> List[Dict]:
        logger.info("----------------- _get_pending_files --------------")
        """
        Get all pending files for a date from DynamoDB.
        Implements pagination to handle large result sets.
        
        Args:
            date_prefix: Date prefix (yyyy-mm-dd)
            
        Returns:
            List of file information dictionaries
        """
        files = []
        last_evaluated_key = None
        
        try:
            while True:
                # Build query parameters
                query_params = {
                    'KeyConditionExpression': 'date_prefix = :prefix',
                    'FilterExpression': '#status = :status',
                    'ExpressionAttributeNames': {'#status': 'status'},
                    'ExpressionAttributeValues': {
                        ':prefix': date_prefix,
                        ':status': 'pending'
                    }
                }
                
                # Add pagination key if not first page
                if last_evaluated_key:
                    query_params['ExclusiveStartKey'] = last_evaluated_key
                
                response = table.query(**query_params)
                
                # Process items
                for item in response.get('Items', []):
                    files.append({
                        'bucket': item['file_path'].split('/')[2],
                        'key': '/'.join(item['file_path'].split('/')[3:]),
                        'filename': item['file_name'],
                        'size_bytes': int(float(item['file_size_mb']) * 1024 * 1024),
                        'size_mb': float(item['file_size_mb']),
                        'date_prefix': item['date_prefix'],
                        's3_path': item['file_path']
                    })
                logger.info(f"files: {files}")
                logger.info(f"files[0]: {files[0]}")
                logger.info(f"files[0]['date_prefix']: {files[0]['date_prefix']}")
                logger.info(f"files[0]['size_bytes']: {files[0]['size_bytes']}")
                # Check if there are more pages
                last_evaluated_key = response.get('LastEvaluatedKey')
                if not last_evaluated_key:
                    break
                
                logger.info(f"Paginating DynamoDB query for {date_prefix}, "
                           f"fetched {len(files)} files so far")
            
            logger.info(f"Retrieved {len(files)} pending files for {date_prefix}")
            return files
            
        except Exception as e:
            logger.error(f"Error querying pending files: {str(e)}")
            return []
    
    def _create_batches(self, files: List[Dict]) -> List[List[Dict]]:
        logger.info("----------------- _create_batches --------------")
        logger.info(f"files: {files}")
        logger.info(f"files[0]: {files[0]}")
        logger.info(f"files[0]['date_prefix']: {files[0]['date_prefix']}")
        logger.info(f"files[0]['size_bytes']: {files[0]['size_bytes']}")
        logger.info(f"files[0]['size_mb']: {files[0]['size_mb']}")
        logger.info(f"files[0]['filename']: {files[0]['filename']}")
        logger.info(f"files[0]['s3_path']: {files[0]['s3_path']}")
        logger.info(f"files[0]['bucket']: {files[0]['bucket']}")
        logger.info(f"files[0]['key']: {files[0]['key']}")
        logger.info(f"files[0]['valid']: {files[0]['valid']}")
        
        """
        Create batches of files up to max size.

        IMPORTANT: All files in the input list must have the same date_prefix.
        This method is called per date group to ensure proper Glue partitioning.

        Args:
            files: List of file information (all with same date_prefix)

        Returns:
            List of batches (each batch is a list of files)
        """
        batches = []
        current_batch = []
        current_size = 0

        for file_info in files:
            if current_size + file_info['size_bytes'] > self.max_batch_size_bytes and current_batch:
                # Start new batch
                batches.append(current_batch)
                current_batch = [file_info]
                current_size = file_info['size_bytes']
            else:
                current_batch.append(file_info)
                current_size += file_info['size_bytes']
        
        # Add final batch if it meets minimum threshold (50% of max)
        # This prevents creating manifests with very few files
        if current_batch:
            if current_size >= self.max_batch_size_bytes * 0.5 or len(batches) == 0:
                batches.append(current_batch)
            else:
                logger.info(f"Holding {len(current_batch)} files ({current_size / (1024**3):.2f}GB) "
                           f"for next batch")

        logger.info(f"batches_files_list: {batches}")
        
        logger.info(f"Batch sizes: {[sum(f['size_bytes'] for f in b) / (1024**3) for b in batches]}")
        logger.info(f"Batch_file_counts: {[len(b) for b in batches]}")
        logger.info(f"Batch file sizes: {[len(b) for b in batches]}")
        logger.info(f"Batch file sizes: {[sum(f['size_mb'] for f in b) for b in batches]}")

        return batches
    
    def _create_manifest(
        self,
        date_prefix: str,
        batch_idx: int,
        files: List[Dict]
    ) -> Optional[str]:

        logger.info("----------------- _create_manifest --------------")
        """
        Create manifest file in S3.

        Args:
            date_prefix: Date prefix (yyyy-mm-dd)
            batch_idx: Batch sequence number
            files: List of files in this batch

        Returns:
            S3 path to manifest file, or None on failure
        """
        try:
            # CRITICAL: Verify all files have the same date prefix
            # This ensures Glue won't error when partitioning
            date_prefixes = {f['date_prefix'] for f in files}
            if len(date_prefixes) > 1:
                logger.error(f"Manifest creation aborted: Multiple date prefixes in batch: {date_prefixes}")
                return None

            if date_prefixes != {date_prefix}:
                logger.error(f"Manifest creation aborted: Files date prefix {date_prefixes} "
                           f"doesn't match expected {date_prefix}")
                return None

            # Create manifest content
            manifest = {
                'fileLocations': [
                    {'URIPrefixes': [f['s3_path']]} for f in files
                ],
                'globalUploadSettings': {
                    'format': 'NDJSON'
                },
                'metadata': {
                    'date_prefix': date_prefix,
                    'batch_idx': batch_idx,
                    'file_count': len(files),
                    'total_size_bytes': sum(f['size_bytes'] for f in files),
                    'created_at': datetime.utcnow().isoformat()
                }
            }
            logger.info(f"Manifest_content: {manifest}")
            logger.info(f"Manifest_files: {files}")
            # Generate manifest filename
            timestamp = datetime.utcnow().strftime('%Y%m%d-%H%M%S')
            manifest_key = f'manifests/{date_prefix}/batch-{batch_idx:04d}-{timestamp}.json'
            logger.info(f"Manifest_key: {manifest_key}")
            
            # Upload to S3
            s3_client.put_object(
                Bucket=MANIFEST_BUCKET,
                Key=manifest_key,
                Body=json.dumps(manifest, indent=2),
                ContentType='application/json'
            )
            
            manifest_path = f's3://{MANIFEST_BUCKET}/{manifest_key}'

            
            logger.info(f"Created manifest: {manifest_path} with {len(files)} files "
                       f"({sum(f['size_bytes'] for f in files) / (1024**3):.2f}GB)")
            
            return manifest_path
            
        except Exception as e:
            logger.error(f"Error creating manifest: {str(e)}")
            return None
    
    def _update_file_status(
        self,
        files: List[Dict],
        status: str,
        manifest_path: str = None
    ):
        logger.info("----------------- _update_file_status --------------")
        """Update file status in DynamoDB."""
        for file_info in files:
            try:
                update_expr = 'SET #status = :status, updated_at = :updated'
                expr_values = {
                    ':status': status,
                    ':updated': datetime.utcnow().isoformat()
                }
                
                if manifest_path:
                    update_expr += ', manifest_path = :manifest'
                    expr_values[':manifest'] = manifest_path
                
                table.update_item(
                    Key={
                        'date_prefix': file_info['date_prefix'],
                        'file_name': file_info['filename']
                    },
                    UpdateExpression=update_expr,
                    ExpressionAttributeNames={'#status': 'status'},
                    ExpressionAttributeValues=expr_values
                )
            except Exception as e:
                logger.error(f"Error updating file status for {file_info['filename']}: {str(e)}")
    
    def _quarantine_file(self, file_info: Dict, reason: str):
        logger.info("----------------- _quarantine_file --------------")
        """Move file to quarantine bucket and update status."""
        try:
            if QUARANTINE_BUCKET and file_info.get('bucket') and file_info.get('key'):
                # Copy to quarantine
                copy_source = {
                    'Bucket': file_info['bucket'],
                    'Key': file_info['key']
                }
                quarantine_key = f"quarantine/{file_info.get('date_prefix', 'unknown')}/{file_info['filename']}"
                
                s3_client.copy_object(
                    CopySource=copy_source,
                    Bucket=QUARANTINE_BUCKET,
                    Key=quarantine_key,
                    Metadata={
                        'quarantine_reason': reason[:256],  # S3 metadata has size limits
                        'quarantine_time': datetime.utcnow().isoformat()
                    },
                    MetadataDirective='REPLACE'
                )
                
                logger.warning(f"Quarantined: {file_info['filename']} - {reason}")
            
            # Update DynamoDB
            if file_info.get('date_prefix'):
                table.put_item(
                    Item={
                        'date_prefix': file_info['date_prefix'],
                        'file_name': file_info['filename'],
                        'file_path': file_info.get('s3_path', ''),
                        'status': 'quarantined',
                        'error': reason,
                        'created_at': datetime.utcnow().isoformat(),
                        'ttl': int((datetime.utcnow() + timedelta(days=30)).timestamp())
                    }
                )
        except Exception as e:
            logger.error(f"Error quarantining file: {str(e)}")


def lambda_handler(event, context):
    logger.info("----------------- lambda_handler --------------")
    """
    AWS Lambda handler function.
    
    Args:
        event: SQS event with S3 notifications
        context: Lambda context
        
    Returns:
        Processing statistics
    """
    logger.info(f"Received {len(event.get('Records', []))} SQS messages")
    
    try:
        builder = ManifestBuilder()
        stats = builder.process_sqs_messages(event.get('Records', []))
        
        logger.info(f"Processing complete: {json.dumps(stats)}")
        
        return {
            'statusCode': 200,
            'body': json.dumps(stats)
        }
        
    except Exception as e:
        logger.error(f"Error in lambda_handler: {str(e)}", exc_info=True)
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e)
            })
        }
