# CHANGELOG

## Version 1.1.0 (December 22, 2025)

### Overview
This release addresses all issues identified in the comprehensive code review. The changes improve reliability, prevent race conditions, enhance error handling, and add data protection safeguards.

---

### Lambda Manifest Builder (`lambda_manifest_builder.py`)

#### 🔧 Bug Fixes
- **Added DynamoDB pagination** - Fixed issue where queries returning >1MB of data would miss files. Now properly paginates through all results.
- **Added distributed locking** - Prevents race conditions when multiple Lambda invocations process the same date prefix simultaneously.

#### ✨ Enhancements
- **Configurable validation parameters** - Moved hardcoded constants to environment variables:
  - `EXPECTED_FILE_SIZE_MB` (default: 3.5)
  - `SIZE_TOLERANCE_PERCENT` (default: 10)
  - `LOCK_TTL_SECONDS` (default: 300)
- **Improved logging** - Added structured logging with more context
- **Better error messages** - More descriptive error messages for debugging
- **Deduplication logic** - Prevents duplicate processing of files already tracked

#### 📝 Code Quality
- Added type hints throughout
- Improved docstrings
- Consistent use of logging module instead of print statements

---

### Lambda Control Plane (`lambda_control_plane.py`)

#### 🔧 Bug Fixes
- **Moved import to top of file** - `import re` was inside a function, now at module level
- **Global S3 client** - Reuse global client for Lambda warm starts (performance improvement)
- **Null safety for metrics table** - Added check before accessing `metrics_table` when not configured

#### ✨ Enhancements
- **Added RUNNING state handler** - Now acknowledges when job starts
- **Enhanced CloudWatch metrics** - Added cost tracking metric and timestamps
- **Improved alert messages** - Added timestamp, environment, and region info to alerts
- **Better file status tracking** - Added logging of update counts

#### 📝 Code Quality
- Added type hints
- Improved error handling
- Consistent logging

---

### Glue Streaming Job (`glue_streaming_job.py`)

#### 🔧 Bug Fixes
- **Fixed bare exception** - Changed `except:` to `except SystemExit:` for proper exception handling when optional args are missing

#### ✨ Enhancements
- **Graceful shutdown handling** - Added signal handlers for SIGTERM and SIGINT
- **Batch metrics publishing** - Publishes processing time to CloudWatch
- **Progress logging** - Periodic logging of stream progress
- **Statistics tracking** - Tracks batches processed, records, and errors
- **Checkpoint cleanup guidance** - Added documentation for S3 lifecycle policy

#### 📝 Code Quality
- Enhanced logging with timing information
- Better error context in log messages
- Added type hints

---

### CloudFormation Template (`cloudformation-sqs-manifest.yaml`)

#### 🔧 Bug Fixes
- **Added DeletionPolicy: Retain** - All S3 buckets and DynamoDB tables now have deletion protection
- **Added UpdateReplacePolicy: Retain** - Prevents accidental data loss during stack updates

#### ✨ Enhancements
- **New S3 logging bucket** - Dedicated bucket for access logs with lifecycle policy
- **S3 access logging** - Input bucket now logs to dedicated logging bucket
- **Checkpoint cleanup lifecycle** - Added 7-day expiration for checkpoint files
- **DynamoDB Point-in-Time Recovery** - Enabled for file tracking table
- **New configurable parameters**:
  - `ExpectedFileSizeMB`
  - `SizeTolerancePercent`
- **New environment variables** for Lambda functions
- **Enhanced dashboard** - Added cost metrics, DLQ monitoring, and batch metrics
- **New alarm** - Queue backlog alarm for high queue depth
- **TreatMissingData** - Added to all alarms for better behavior
- **RUNNING state** - Added to EventBridge rule to track job starts

#### 📝 Outputs
- Added outputs for:
  - QuarantineBucketName
  - LoggingBucketName
  - SQSDLQUrl
  - MetricsTableName
  - AlertTopicArn

---

### Summary of Fixes by Priority

| Priority | Issue | Status |
|----------|-------|--------|
| Medium | DynamoDB pagination missing | ✅ Fixed |
| Medium | Race condition in manifest creation | ✅ Fixed |
| Medium | S3 bucket deletion protection | ✅ Fixed |
| Low | Import inside function | ✅ Fixed |
| Low | S3 client recreation | ✅ Fixed |
| Low | Metrics table conditional access | ✅ Fixed |
| Low | Bare exception clause | ✅ Fixed |
| Low | Checkpoint cleanup | ✅ Documented |

---

### Migration Guide

#### Environment Variables
Add these new environment variables to Lambda functions:
```bash
# Manifest Builder
EXPECTED_FILE_SIZE_MB=3.5
SIZE_TOLERANCE_PERCENT=10
LOCK_TTL_SECONDS=300
```

#### CloudFormation Update
```bash
aws cloudformation update-stack \
  --stack-name ndjson-parquet-sqs \
  --template-body file://cloudformation-sqs-manifest.yaml \
  --parameters file://parameters.json \
  --capabilities CAPABILITY_NAMED_IAM
```

#### Lambda Code Update
```bash
# Update Manifest Builder
zip -r manifest-builder.zip lambda_manifest_builder.py
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --zip-file fileb://manifest-builder.zip

# Update Control Plane
zip -r control-plane.zip lambda_control_plane.py
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-control-plane \
  --zip-file fileb://control-plane.zip
```

#### Glue Script Update
```bash
aws s3 cp glue_streaming_job.py \
  s3://${MANIFEST_BUCKET}/scripts/glue_streaming_job.py

# Restart Glue job to pick up changes
aws glue stop-job-run --job-name <JOB_NAME> --job-run-id <RUN_ID>
aws glue start-job-run --job-name <JOB_NAME>
```

---

### Testing Checklist

- [ ] Deploy CloudFormation changes
- [ ] Update Lambda functions
- [ ] Update Glue script
- [ ] Restart Glue job
- [ ] Upload test files
- [ ] Verify pagination works (upload >300 files for single date)
- [ ] Verify locking (concurrent Lambda invocations)
- [ ] Check CloudWatch dashboard
- [ ] Verify alerts are working
- [ ] Test DLQ handling

---

**Reviewed and Updated by:** Claude (Opus 4.5)  
**Date:** December 22, 2025
