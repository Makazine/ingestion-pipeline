"""
Lambda #2: Control Plane (Glue State Handler)
==============================================

Triggered by EventBridge when Glue job state changes.
Manages job state, updates metrics, handles failures, and triggers alerts.

Author: Data Engineering Team
Version: 1.1.0 (Updated with code review fixes)

Changes in 1.1.0:
- Moved imports to top of file
- Reuse global S3 client for Lambda warm starts
- Added null check for metrics_table
- Improved logging consistency
- Enhanced error messages
"""

import json
import os
import re
import logging
import boto3
from datetime import datetime
from decimal import Decimal
from typing import Dict, List, Optional

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS Clients (reused across invocations for Lambda warm starts)
dynamodb = boto3.resource('dynamodb')
cloudwatch = boto3.client('cloudwatch')
sns = boto3.client('sns')
glue_client = boto3.client('glue')
s3_client = boto3.client('s3')  # Global S3 client for reuse

# Environment Variables
TRACKING_TABLE = os.environ['TRACKING_TABLE']
METRICS_TABLE = os.environ.get('METRICS_TABLE', '')
ALERT_TOPIC_ARN = os.environ.get('ALERT_TOPIC_ARN', '')
GLUE_JOB_NAME = os.environ['GLUE_JOB_NAME']

# DynamoDB tables (with null safety)
tracking_table = dynamodb.Table(TRACKING_TABLE)
metrics_table = dynamodb.Table(METRICS_TABLE) if METRICS_TABLE else None


class ControlPlane:
    """Manages Glue job state and metrics."""
    
    def __init__(self):
        self.alert_topic = ALERT_TOPIC_ARN
    
    def handle_state_change(self, event: Dict) -> Dict:
        """
        Handle Glue job state change event.
        
        Args:
            event: EventBridge event for Glue job state change
            
        Returns:
            Processing result
        """
        detail = event['detail']
        job_name = detail['jobName']
        job_run_id = detail['jobRunId']
        state = detail['state']
        
        logger.info(f"Glue job {job_name} run {job_run_id} changed to state: {state}")
        
        result = {
            'job_name': job_name,
            'job_run_id': job_run_id,
            'state': state,
            'timestamp': event['time']
        }
        
        # Get job run details
        job_details = self._get_job_run_details(job_name, job_run_id)
        
        if state == 'SUCCEEDED':
            result.update(self._handle_success(job_details))
        elif state == 'FAILED':
            result.update(self._handle_failure(job_details))
        elif state == 'TIMEOUT':
            result.update(self._handle_timeout(job_details))
        elif state == 'STOPPED':
            result.update(self._handle_stopped(job_details))
        elif state == 'RUNNING':
            result.update(self._handle_running(job_details))
        
        # Update metrics
        self._update_metrics(job_details, state)
        
        # Publish CloudWatch metrics
        self._publish_cloudwatch_metrics(job_details, state)
        
        return result
    
    def _get_job_run_details(self, job_name: str, job_run_id: str) -> Dict:
        """Get detailed information about job run."""
        try:
            response = glue_client.get_job_run(
                JobName=job_name,
                RunId=job_run_id
            )
            
            job_run = response['JobRun']
            
            # Extract arguments
            args = job_run.get('Arguments', {})
            
            details = {
                'job_name': job_name,
                'job_run_id': job_run_id,
                'state': job_run['JobRunState'],
                'started_on': job_run.get('StartedOn'),
                'completed_on': job_run.get('CompletedOn'),
                'execution_time_seconds': job_run.get('ExecutionTime', 0),
                'max_capacity': job_run.get('MaxCapacity', 0),
                'worker_type': job_run.get('WorkerType', 'G.2X'),
                'number_of_workers': job_run.get('NumberOfWorkers', 0),
                'error_message': job_run.get('ErrorMessage', ''),
                'manifest_path': args.get('--MANIFEST_PATH', ''),
                'date_prefix': args.get('--DATE_PREFIX', ''),
                'dpu_seconds': job_run.get('ExecutionTime', 0) * job_run.get('NumberOfWorkers', 0)
            }
            
            return details
            
        except Exception as e:
            logger.error(f"Error getting job run details: {str(e)}")
            return {
                'job_name': job_name,
                'job_run_id': job_run_id,
                'error': str(e)
            }
    
    def _handle_success(self, job_details: Dict) -> Dict:
        """Handle successful job completion."""
        logger.info(f"Job succeeded: {job_details['job_run_id']}")
        
        # Update file statuses to 'completed'
        if job_details.get('manifest_path'):
            self._update_files_from_manifest(
                job_details['manifest_path'],
                'completed',
                job_details['job_run_id']
            )
        
        # Check for anomalies
        anomalies = self._detect_anomalies(job_details)
        
        if anomalies:
            self._send_alert(
                'Anomaly Detected',
                f"Job {job_details['job_run_id']} completed but with anomalies:\n" +
                '\n'.join(f"  - {a}" for a in anomalies),
                'WARNING'
            )
        
        return {
            'action': 'success_handled',
            'anomalies': anomalies,
            'execution_time': job_details.get('execution_time_seconds', 0)
        }
    
    def _handle_failure(self, job_details: Dict) -> Dict:
        """Handle job failure."""
        error_msg = job_details.get('error_message', 'Unknown error')
        
        logger.error(f"Job failed: {job_details['job_run_id']} - {error_msg}")
        
        # Update file statuses to 'failed'
        if job_details.get('manifest_path'):
            self._update_files_from_manifest(
                job_details['manifest_path'],
                'failed',
                job_details['job_run_id'],
                error_msg
            )
        
        # Send alert
        self._send_alert(
            'Glue Job Failed',
            f"Job: {job_details['job_name']}\n"
            f"Run ID: {job_details['job_run_id']}\n"
            f"Error: {error_msg}\n"
            f"Date: {job_details.get('date_prefix', 'unknown')}\n"
            f"Manifest: {job_details.get('manifest_path', 'N/A')}",
            'ERROR'
        )
        
        return {
            'action': 'failure_handled',
            'error': error_msg,
            'alert_sent': True
        }
    
    def _handle_timeout(self, job_details: Dict) -> Dict:
        """Handle job timeout."""
        logger.error(f"Job timed out: {job_details['job_run_id']}")
        
        # Update file statuses
        if job_details.get('manifest_path'):
            self._update_files_from_manifest(
                job_details['manifest_path'],
                'timeout',
                job_details['job_run_id'],
                'Job execution timed out'
            )
        
        # Send alert
        self._send_alert(
            'Glue Job Timeout',
            f"Job: {job_details['job_name']}\n"
            f"Run ID: {job_details['job_run_id']}\n"
            f"Execution time: {job_details.get('execution_time_seconds', 0)} seconds\n"
            f"Execution time exceeded maximum timeout",
            'ERROR'
        )
        
        return {
            'action': 'timeout_handled',
            'alert_sent': True
        }
    
    def _handle_stopped(self, job_details: Dict) -> Dict:
        """Handle manually stopped job."""
        logger.info(f"Job stopped: {job_details['job_run_id']}")
        
        # Update file statuses
        if job_details.get('manifest_path'):
            self._update_files_from_manifest(
                job_details['manifest_path'],
                'stopped',
                job_details['job_run_id'],
                'Job manually stopped'
            )
        
        return {
            'action': 'stopped_handled'
        }
    
    def _handle_running(self, job_details: Dict) -> Dict:
        """Handle job started running."""
        logger.info(f"Job started: {job_details['job_run_id']}")
        
        return {
            'action': 'running_acknowledged',
            'started_on': str(job_details.get('started_on', ''))
        }
    
    def _update_files_from_manifest(
        self,
        manifest_path: str,
        status: str,
        job_run_id: str,
        error: str = None
    ):
        """Update status of all files in a manifest."""
        try:
            # Parse manifest path
            bucket = manifest_path.split('/')[2]
            key = '/'.join(manifest_path.split('/')[3:])
            
            # Read manifest using global S3 client
            response = s3_client.get_object(Bucket=bucket, Key=key)
            manifest = json.loads(response['Body'].read().decode('utf-8'))
            
            # Extract file paths
            file_paths = []
            for location in manifest.get('fileLocations', []):
                for uri in location.get('URIPrefixes', []):
                    file_paths.append(uri)
            
            logger.info(f"Updating {len(file_paths)} files to status: {status}")
            
            # Update each file in DynamoDB
            updated_count = 0
            error_count = 0
            
            for file_path in file_paths:
                filename = file_path.split('/')[-1]
                
                # Extract date prefix from filename (import moved to top)
                date_match = re.match(r'(\d{4}-\d{2}-\d{2})-', filename)
                if not date_match:
                    logger.warning(f"Could not extract date prefix from filename: {filename}")
                    continue
                
                date_prefix = date_match.group(1)
                
                update_expr = 'SET #status = :status, job_run_id = :job_id, updated_at = :updated'
                expr_values = {
                    ':status': status,
                    ':job_id': job_run_id,
                    ':updated': datetime.utcnow().isoformat()
                }
                
                if error:
                    update_expr += ', error_message = :error'
                    expr_values[':error'] = error
                
                try:
                    tracking_table.update_item(
                        Key={
                            'date_prefix': date_prefix,
                            'file_name': filename
                        },
                        UpdateExpression=update_expr,
                        ExpressionAttributeNames={'#status': 'status'},
                        ExpressionAttributeValues=expr_values
                    )
                    updated_count += 1
                except Exception as e:
                    logger.error(f"Error updating file {filename}: {str(e)}")
                    error_count += 1
            
            logger.info(f"Updated {updated_count} files, {error_count} errors")
                    
        except Exception as e:
            logger.error(f"Error updating files from manifest: {str(e)}")
    
    def _detect_anomalies(self, job_details: Dict) -> List[str]:
        """Detect anomalies in job execution."""
        anomalies = []
        
        # Expected execution time (based on 1GB batches at ~3.5MB per file)
        # ~286 files per batch, should process in 2-5 minutes
        expected_min_time = 120  # 2 minutes
        expected_max_time = 300  # 5 minutes
        
        execution_time = job_details.get('execution_time_seconds', 0)
        
        if execution_time < expected_min_time:
            anomalies.append(
                f"Execution time too short: {execution_time}s (expected {expected_min_time}-{expected_max_time}s)"
            )
        elif execution_time > expected_max_time * 1.5:
            anomalies.append(
                f"Execution time too long: {execution_time}s (expected {expected_min_time}-{expected_max_time}s)"
            )
        
        # Check DPU usage
        dpu_seconds = job_details.get('dpu_seconds', 0)
        num_workers = job_details.get('number_of_workers', 0)
        
        if num_workers > 0:
            avg_dpu = dpu_seconds / num_workers
            if avg_dpu > expected_max_time * 1.5:
                anomalies.append(
                    f"High DPU usage: {avg_dpu:.0f} DPU-seconds per worker"
                )
        
        return anomalies
    
    def _update_metrics(self, job_details: Dict, state: str):
        """Update metrics in DynamoDB."""
        # Check if metrics table is configured
        if not metrics_table:
            logger.debug("Metrics table not configured, skipping metrics update")
            return
        
        try:
            metric_date = datetime.utcnow().strftime('%Y-%m-%d')
            ttl = int((datetime.utcnow().timestamp()) + (30 * 24 * 3600))  # 30 days
            
            # Calculate cost (approximate)
            dpu_hours = job_details.get('dpu_seconds', 0) / 3600
            cost_per_dpu_hour = 0.44
            estimated_cost = dpu_hours * cost_per_dpu_hour
            
            metrics_table.put_item(
                Item={
                    'metric_date': metric_date,
                    'metric_type': f'job_run#{job_details["job_run_id"]}',
                    'job_name': job_details.get('job_name', ''),
                    'state': state,
                    'execution_time_seconds': job_details.get('execution_time_seconds', 0),
                    'dpu_seconds': job_details.get('dpu_seconds', 0),
                    'estimated_cost_usd': Decimal(str(round(estimated_cost, 4))),
                    'worker_type': job_details.get('worker_type', ''),
                    'number_of_workers': job_details.get('number_of_workers', 0),
                    'date_prefix': job_details.get('date_prefix', ''),
                    'manifest_path': job_details.get('manifest_path', ''),
                    'timestamp': datetime.utcnow().isoformat(),
                    'ttl': ttl
                }
            )
            
            logger.info(f"Metrics updated for job run {job_details.get('job_run_id', 'unknown')}")
            
        except Exception as e:
            logger.error(f"Error updating metrics: {str(e)}")
    
    def _publish_cloudwatch_metrics(self, job_details: Dict, state: str):
        """Publish custom CloudWatch metrics."""
        try:
            namespace = 'NDJSONPipeline'
            timestamp = datetime.utcnow()
            
            metrics = [
                {
                    'MetricName': 'JobExecutionTime',
                    'Value': job_details.get('execution_time_seconds', 0),
                    'Unit': 'Seconds',
                    'Timestamp': timestamp,
                    'Dimensions': [
                        {'Name': 'JobName', 'Value': job_details.get('job_name', GLUE_JOB_NAME)},
                        {'Name': 'State', 'Value': state}
                    ]
                },
                {
                    'MetricName': 'DPUSeconds',
                    'Value': job_details.get('dpu_seconds', 0),
                    'Unit': 'Count',
                    'Timestamp': timestamp,
                    'Dimensions': [
                        {'Name': 'JobName', 'Value': job_details.get('job_name', GLUE_JOB_NAME)},
                        {'Name': 'WorkerType', 'Value': job_details.get('worker_type', 'G.2X')}
                    ]
                },
                {
                    'MetricName': 'JobRuns',
                    'Value': 1,
                    'Unit': 'Count',
                    'Timestamp': timestamp,
                    'Dimensions': [
                        {'Name': 'JobName', 'Value': job_details.get('job_name', GLUE_JOB_NAME)},
                        {'Name': 'State', 'Value': state}
                    ]
                }
            ]
            
            # Add cost metric for completed jobs
            if state in ['SUCCEEDED', 'FAILED', 'TIMEOUT']:
                dpu_hours = job_details.get('dpu_seconds', 0) / 3600
                estimated_cost = dpu_hours * 0.44
                metrics.append({
                    'MetricName': 'EstimatedCostUSD',
                    'Value': estimated_cost,
                    'Unit': 'None',
                    'Timestamp': timestamp,
                    'Dimensions': [
                        {'Name': 'JobName', 'Value': job_details.get('job_name', GLUE_JOB_NAME)}
                    ]
                })
            
            cloudwatch.put_metric_data(
                Namespace=namespace,
                MetricData=metrics
            )
            
            logger.debug(f"Published {len(metrics)} CloudWatch metrics")
            
        except Exception as e:
            logger.error(f"Error publishing CloudWatch metrics: {str(e)}")
    
    def _send_alert(self, subject: str, message: str, severity: str = 'INFO'):
        """Send SNS alert."""
        if not self.alert_topic:
            logger.warning(f"No alert topic configured. Alert: [{severity}] {subject}")
            return
        
        try:
            # Add timestamp and environment info to message
            full_message = (
                f"Time: {datetime.utcnow().isoformat()}Z\n"
                f"Environment: {os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'local')}\n"
                f"Region: {os.environ.get('AWS_REGION', 'unknown')}\n"
                f"\n{message}"
            )
            
            sns.publish(
                TopicArn=self.alert_topic,
                Subject=f'[{severity}] {subject}'[:100],  # SNS subject limit
                Message=full_message,
                MessageAttributes={
                    'severity': {
                        'DataType': 'String',
                        'StringValue': severity
                    }
                }
            )
            logger.info(f"Alert sent: [{severity}] {subject}")
        except Exception as e:
            logger.error(f"Error sending alert: {str(e)}")


def lambda_handler(event, context):
    """
    AWS Lambda handler function.
    
    Args:
        event: EventBridge event for Glue job state change
        context: Lambda context
        
    Returns:
        Processing result
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    try:
        control_plane = ControlPlane()
        result = control_plane.handle_state_change(event)
        
        logger.info(f"Processing complete: {json.dumps(result, default=str)}")
        
        return {
            'statusCode': 200,
            'body': json.dumps(result, default=str)
        }
        
    except Exception as e:
        logger.error(f"Error in lambda_handler: {str(e)}", exc_info=True)
        return {
            'statusCode': 500,
            'body': json.dumps({
                'error': str(e)
            })
        }
