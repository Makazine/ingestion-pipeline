# SQS + Manifest + Glue Streaming: NDJSON to Parquet Pipeline

## 🎯 Overview

Production-grade data pipeline for converting high-volume NDJSON files (~200,000 files/hour) to optimized Parquet format using SQS for reliability, manifest-based batching for efficiency, and Glue Streaming for continuous processing.

### Key Features

✅ **SQS Decoupling** - Handles 55 files/second with built-in retry and DLQ  
✅ **Manifest Batching** - Groups files into 1GB batches (~286 files each)  
✅ **Glue Streaming** - 24/7 processing with minimal latency  
✅ **Control Plane** - Centralized state management and monitoring  
✅ **Auto-Scaling** - Handles traffic spikes seamlessly  
✅ **Data Validation** - Pre-processing validation and quarantine  

### Architecture

```
S3 Input → SQS → Lambda (Manifest Builder) → S3 Manifests
                                                    ↓
                                           Glue Streaming → S3 Output
                                                    ↓
                                        EventBridge → Lambda (Control Plane)
```

## 📊 Performance & Cost

| Metric | Value |
|--------|-------|
| **Throughput** | 700GB/hour (200,000 files) |
| **File Size** | 3.5MB (uniform) |
| **Batch Size** | 1GB (~286 files) |
| **Processing Time** | 2-5 minutes per batch |
| **Monthly Cost** | ~$14,850 |
| **Cost Savings** | 11.8% vs baseline |

## 📁 Repository Structure

```
ndjson-parquet-sqs/
├── README.md                              # This file
├── cloudformation-sqs-manifest.yaml       # Complete infrastructure
├── lambda_manifest_builder.py             # Lambda #1
├── lambda_control_plane.py                # Lambda #2
├── glue_streaming_job.py                  # Glue PySpark job
├── sqs-manifest-architecture.mermaid      # Architecture diagram
├── deployment/
│   ├── deploy.sh                          # Deployment script
│   ├── parameters.json                    # Configuration
│   └── test-data/
│       └── generate_test_files.py         # Test data generator
└── docs/
    ├── SETUP.md                           # Detailed setup guide
    └── TROUBLESHOOTING.md                 # Common issues
```

## 🚀 Quick Start (30 Minutes)

### Prerequisites

- AWS Account with Admin access
- AWS CLI configured (`aws configure`)
- Python 3.11+
- Valid email for alerts

### Step 1: Configure Parameters

Create `parameters.json`:

```json
{
  "ProjectName": "ndjson-parquet-sqs",
  "InputBucketName": "your-ndjson-input",
  "ManifestBucketName": "your-manifests",
  "OutputBucketName": "your-parquet-output",
  "QuarantineBucketName": "your-quarantine",
  "MaxBatchSizeGB": "1.0",
  "GlueWorkerType": "G.2X",
  "GlueNumberOfWorkers": "10",
  "AlertEmail": "your-email@example.com"
}
```

### Step 2: Deploy Infrastructure

```bash
# Deploy CloudFormation stack
aws cloudformation create-stack \
  --stack-name ndjson-parquet-sqs \
  --template-body file://cloudformation-sqs-manifest.yaml \
  --parameters file://parameters.json \
  --capabilities CAPABILITY_NAMED_IAM

# Wait for completion (5-10 minutes)
aws cloudformation wait stack-create-complete \
  --stack-name ndjson-parquet-sqs

# Get stack outputs
aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].Outputs'
```

### Step 3: Upload Lambda Code

```bash
# Get manifest bucket from outputs
MANIFEST_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].Outputs[?OutputKey==`ManifestBucketName`].OutputValue' \
  --output text)

# Package Lambda #1
cd lambda/
zip manifest-builder.zip lambda_manifest_builder.py
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --zip-file fileb://manifest-builder.zip

# Package Lambda #2
zip control-plane.zip lambda_control_plane.py
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-control-plane \
  --zip-file fileb://control-plane.zip
```

### Step 4: Upload Glue Script

```bash
# Upload Glue job script
aws s3 cp glue_streaming_job.py \
  s3://${MANIFEST_BUCKET}/scripts/glue_streaming_job.py
```

### Step 5: Start Glue Job

```bash
# Start the streaming job (runs 24/7)
aws glue start-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor

# Monitor job status
aws glue get-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --run-id <JOB_RUN_ID>
```

### Step 6: Test with Sample Data

```bash
# Get input bucket
INPUT_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].Outputs[?OutputKey==`InputBucketName`].OutputValue' \
  --output text)

# Generate test files (3.5MB each)
python deployment/test-data/generate_test_files.py --count 300 --output /tmp/test-files/

# Upload test files
aws s3 sync /tmp/test-files/ s3://${INPUT_BUCKET}/

# Monitor SQS queue
aws sqs get-queue-attributes \
  --queue-url $(aws cloudformation describe-stacks \
    --stack-name ndjson-parquet-sqs \
    --query 'Stacks[0].Outputs[?OutputKey==`SQSQueueURL`].OutputValue' \
    --output text) \
  --attribute-names ApproximateNumberOfMessages

# Monitor Lambda logs
aws logs tail /aws/lambda/ndjson-parquet-sqs-manifest-builder --follow
```

## 📋 Detailed Configuration

### SQS Queue Settings

```yaml
VisibilityTimeout: 900 seconds      # 15 minutes (5x Lambda timeout)
MessageRetentionPeriod: 1209600     # 14 days
MaxReceiveCount: 3                  # DLQ after 3 failures
LongPolling: 20 seconds             # Efficient polling
```

**Why these settings:**
- 15-min visibility allows Lambda to process large batches
- 14-day retention prevents data loss during outages
- DLQ catches problematic messages for manual review

### Lambda #1: Manifest Builder

```yaml
Memory: 512 MB
Timeout: 180 seconds
Batch Size: 10 messages
Batching Window: 30 seconds
```

**Processing logic:**
1. Receives SQS messages (S3 events)
2. Validates file size (3.5MB ± 10%)
3. Tracks files in DynamoDB
4. Groups by date prefix
5. Creates 1GB manifests when ready
6. Quarantines invalid files

### Lambda #2: Control Plane

```yaml
Memory: 256 MB
Timeout: 60 seconds
Trigger: EventBridge (Glue state changes)
```

**Responsibilities:**
- Updates file status in DynamoDB
- Publishes CloudWatch metrics
- Detects anomalies
- Sends SNS alerts on failures
- Tracks costs and performance

### Glue Streaming Job

```yaml
Worker Type: G.2X (8 vCPU, 32GB RAM)
Number of Workers: 10
Max Concurrent Runs: 1
Timeout: 48 hours
Mode: Streaming (24/7)
```

**Processing:**
1. Watches manifest directory continuously
2. Reads batches of ~286 files each
3. Merges NDJSON to DataFrame
4. Casts all columns to string
5. Converts to Parquet (Snappy)
6. Writes with date partitioning

### DynamoDB Schema

**File Tracking Table:**
```
PK: date_prefix (yyyy-mm-dd)
SK: file_name
Attributes:
  - file_path (S3 URI)
  - file_size_mb (Number)
  - status (String: pending|manifested|completed|failed|quarantined)
  - manifest_path (String)
  - job_run_id (String)
  - created_at (String: ISO timestamp)
  - updated_at (String)
  - error_message (String, optional)
  - ttl (Number: 7 days)
```

**Metrics Table:**
```
PK: metric_date (yyyy-mm-dd)
SK: metric_type (job_run#<id>)
Attributes:
  - job_name (String)
  - state (String)
  - execution_time_seconds (Number)
  - dpu_seconds (Number)
  - estimated_cost_usd (Number)
  - worker_type (String)
  - number_of_workers (Number)
  - ttl (Number: 30 days)
```

## 🔍 Monitoring

### CloudWatch Dashboard

Access at: `https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=ndjson-parquet-sqs-pipeline`

**Key Metrics:**
1. **SQS Metrics**
   - Messages sent
   - Queue depth
   - DLQ messages

2. **Lambda Metrics**
   - Invocations
   - Errors
   - Duration
   - Concurrent executions

3. **Glue Metrics**
   - Job runs
   - Execution time
   - DPU usage
   - Success/failure rate

4. **Custom Metrics** (via Control Plane)
   - Cost per GB processed
   - Files processed per hour
   - Average batch size
   - Processing latency

### CloudWatch Alarms

Configured alarms:
- **SQS DLQ Messages** - Alert if any messages in DLQ
- **Manifest Builder Errors** - Alert if >5 errors in 5 minutes
- **Glue Job Failure** - Alert on any job failure

### Logging

**Lambda Logs:**
```bash
# Manifest Builder
aws logs tail /aws/lambda/ndjson-parquet-sqs-manifest-builder --follow

# Control Plane
aws logs tail /aws/lambda/ndjson-parquet-sqs-control-plane --follow
```

**Glue Logs:**
```bash
# Continuous logs
aws logs tail /aws-glue/jobs/output --follow

# Error logs
aws logs tail /aws-glue/jobs/error --follow
```

## 🔧 Operational Tasks

### Checking Pipeline Health

```bash
# Check SQS queue depth
aws sqs get-queue-attributes \
  --queue-url <QUEUE_URL> \
  --attribute-names ApproximateNumberOfMessages

# Check Glue job status
aws glue get-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --run-id <JOB_RUN_ID>

# Query file status in DynamoDB
aws dynamodb query \
  --table-name ndjson-parquet-sqs-file-tracking \
  --key-condition-expression "date_prefix = :date" \
  --expression-attribute-values '{":date":{"S":"2025-12-21"}}'
```

### Scaling Glue Workers

```bash
# Update number of workers
aws glue update-job \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --job-update NumberOfWorkers=20

# Restart job with new settings
aws glue start-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor
```

### Reprocessing Failed Files

```bash
# Query failed files
aws dynamodb query \
  --table-name ndjson-parquet-sqs-file-tracking \
  --index-name status-index \
  --key-condition-expression "#status = :status" \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{":status":{"S":"failed"}}'

# Update status to pending for reprocessing
aws dynamodb update-item \
  --table-name ndjson-parquet-sqs-file-tracking \
  --key '{"date_prefix":{"S":"2025-12-21"},"file_name":{"S":"filename.ndjson"}}' \
  --update-expression "SET #status = :status" \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{":status":{"S":"pending"}}'
```

## 🐛 Troubleshooting

### Issue: Messages stuck in SQS queue

**Symptoms:** Queue depth increasing, files not being processed

**Checks:**
```bash
# Check Lambda is enabled
aws lambda get-function --function-name ndjson-parquet-sqs-manifest-builder

# Check event source mapping
aws lambda list-event-source-mappings \
  --function-name ndjson-parquet-sqs-manifest-builder
```

**Solution:**
```bash
# Enable event source mapping if disabled
aws lambda update-event-source-mapping \
  --uuid <MAPPING_UUID> \
  --enabled
```

### Issue: Glue job not picking up manifests

**Symptoms:** Manifests created but not processed

**Checks:**
```bash
# Verify Glue job is running
aws glue get-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --run-id <JOB_RUN_ID>

# Check manifest bucket permissions
aws s3 ls s3://<MANIFEST_BUCKET>/manifests/
```

**Solution:**
```bash
# Restart Glue job
aws glue stop-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --job-run-id <JOB_RUN_ID>

aws glue start-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor
```

### Issue: High costs

**Analysis:**
```bash
# Check Glue job metrics
aws cloudwatch get-metric-statistics \
  --namespace NDJSONPipeline \
  --metric-name DPUSeconds \
  --start-time 2025-12-20T00:00:00Z \
  --end-time 2025-12-21T00:00:00Z \
  --period 3600 \
  --statistics Sum

# Query metrics table
aws dynamodb query \
  --table-name ndjson-parquet-sqs-metrics \
  --key-condition-expression "metric_date = :date" \
  --expression-attribute-values '{":date":{"S":"2025-12-21"}}'
```

**Optimization:**
- Reduce Glue workers if underutilized
- Adjust batch size to process more files per job
- Review Spark configuration in Glue job

### Issue: Files going to quarantine

**Check quarantine bucket:**
```bash
aws s3 ls s3://<QUARANTINE_BUCKET>/quarantine/

# Download and inspect
aws s3 cp s3://<QUARANTINE_BUCKET>/quarantine/2025-12-21/file.ndjson /tmp/

# Check file size
ls -lh /tmp/file.ndjson
```

**Common causes:**
- File size != 3.5MB ± 10%
- Invalid filename format (not yyyy-mm-dd-*.ndjson)
- Corrupted NDJSON content

## 💰 Cost Optimization

### Current Costs (700GB/hour, 24/7)

| Service | Monthly Cost | Notes |
|---------|-------------|-------|
| SQS | $58 | 144M requests |
| Lambda #1 | $100 | Manifest builder |
| Lambda #2 | $5 | Control plane |
| Glue Streaming | $3,168 | 10 workers, 24/7 |
| S3 Storage | $11,500 | 500TB |
| DynamoDB | $20 | On-demand |
| CloudWatch | $15 | Logs + metrics |
| **Total** | **$14,866** | |

### Optimization Tips

1. **Glue Workers** - Start with 10, adjust based on queue depth
2. **Batch Size** - Increase to 2GB if processing is smooth
3. **S3 Intelligent-Tiering** - Already configured for old data
4. **DynamoDB** - On-demand is cheapest for this workload
5. **CloudWatch Logs** - Set retention to 7 days

## 🔐 Security Best Practices

✅ **Implemented:**
- S3 bucket encryption (SSE-S3)
- IAM roles with least privilege
- S3 bucket policies (block public access)
- VPC endpoints for S3 (optional)
- CloudTrail logging
- S3 versioning

🔒 **Recommended:**
- Enable S3 access logging
- Use KMS for encryption
- Implement VPC for Glue jobs
- Regular security audits
- Enable GuardDuty

## 📚 Additional Resources

- [AWS Glue Streaming Documentation](https://docs.aws.amazon.com/glue/latest/dg/add-job-streaming.html)
- [SQS Best Practices](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-best-practices.html)
- [Parquet Format](https://parquet.apache.org/docs/)
- [PySpark Documentation](https://spark.apache.org/docs/latest/api/python/)

## 🤝 Support

**Issues:** Create GitHub issue  
**Alerts:** Check SNS topic subscriptions  
**On-call:** PagerDuty integration  

---

**Version:** 1.0.0  
**Last Updated:** December 21, 2025  
**Maintained By:** Data Engineering Team
