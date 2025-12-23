# Detailed Setup & Deployment Guide

## 📋 Pre-Deployment Checklist

### AWS Prerequisites
- [ ] AWS Account with Admin access
- [ ] AWS CLI installed and configured
- [ ] Python 3.11+ installed
- [ ] Valid email address for alerts
- [ ] Sufficient AWS service quotas:
  - SQS: At least 1,000 queues per region
  - Lambda: At least 1,000 concurrent executions
  - Glue: At least 10 DPUs available
  - S3: No bucket limit concerns

### Verify AWS CLI Configuration
```bash
# Check AWS CLI version (should be 2.x)
aws --version

# Verify credentials
aws sts get-caller-identity

# Check region
aws configure get region
```

## 🔧 Step-by-Step Deployment

### Step 1: Prepare Configuration Files

#### 1.1 Create `parameters.json`

```bash
cat > parameters.json << 'EOF'
{
  "ProjectName": "ndjson-parquet-sqs",
  "InputBucketName": "ndjson-input-prod",
  "ManifestBucketName": "ndjson-manifests-prod",
  "OutputBucketName": "parquet-output-prod",
  "QuarantineBucketName": "ndjson-quarantine-prod",
  "MaxBatchSizeGB": "1.0",
  "GlueWorkerType": "G.2X",
  "GlueNumberOfWorkers": "10",
  "AlertEmail": "your-email@example.com"
}
EOF
```

**Important:** Update `AlertEmail` with your actual email address!

#### 1.2 Validate CloudFormation Template

```bash
aws cloudformation validate-template \
  --template-body file://cloudformation-sqs-manifest.yaml
```

Expected output: Template details with no errors

### Step 2: Deploy Infrastructure

#### 2.1 Create CloudFormation Stack

```bash
aws cloudformation create-stack \
  --stack-name ndjson-parquet-sqs \
  --template-body file://cloudformation-sqs-manifest.yaml \
  --parameters file://parameters.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --tags Key=Environment,Value=Production Key=Team,Value=DataEngineering
```

Expected output:
```json
{
    "StackId": "arn:aws:cloudformation:us-east-1:123456789012:stack/ndjson-parquet-sqs/..."
}
```

#### 2.2 Monitor Stack Creation

```bash
# Watch stack events
aws cloudformation describe-stack-events \
  --stack-name ndjson-parquet-sqs \
  --max-items 20

# Or use wait command (blocks until complete)
aws cloudformation wait stack-create-complete \
  --stack-name ndjson-parquet-sqs
```

**Timeline:** Expect 5-10 minutes for complete deployment

#### 2.3 Verify Stack Outputs

```bash
aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
  --output table
```

Save these outputs - you'll need them!

### Step 3: Configure Email Alerts

#### 3.1 Confirm SNS Subscription

After stack creation, check your email for AWS SNS confirmation:

```
Subject: AWS Notification - Subscription Confirmation
From: no-reply@sns.amazonaws.com
```

Click the "Confirm subscription" link in the email.

#### 3.2 Verify Subscription

```bash
ALERT_TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].Outputs[?OutputKey==`AlertTopicArn`].OutputValue' \
  --output text)

aws sns list-subscriptions-by-topic \
  --topic-arn $ALERT_TOPIC_ARN
```

Status should be: `"SubscriptionArn": "arn:aws:sns:..."` (not "PendingConfirmation")

### Step 4: Deploy Lambda Functions

#### 4.1 Get Manifest Bucket Name

```bash
export MANIFEST_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].Outputs[?OutputKey==`ManifestBucketName`].OutputValue' \
  --output text)

echo "Manifest Bucket: $MANIFEST_BUCKET"
```

#### 4.2 Package and Deploy Lambda #1 (Manifest Builder)

```bash
# Create deployment package
cd lambda/
zip -r manifest-builder.zip lambda_manifest_builder.py

# Upload to Lambda
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --zip-file fileb://manifest-builder.zip

# Wait for update to complete
aws lambda wait function-updated \
  --function-name ndjson-parquet-sqs-manifest-builder

# Verify
aws lambda get-function \
  --function-name ndjson-parquet-sqs-manifest-builder \
  --query 'Configuration.[Runtime,MemorySize,Timeout]'
```

Expected output: `["python3.11", 512, 180]`

#### 4.3 Package and Deploy Lambda #2 (Control Plane)

```bash
# Create deployment package
zip -r control-plane.zip lambda_control_plane.py

# Upload to Lambda
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-control-plane \
  --zip-file fileb://control-plane.zip

# Wait for update
aws lambda wait function-updated \
  --function-name ndjson-parquet-sqs-control-plane

# Verify
aws lambda get-function \
  --function-name ndjson-parquet-sqs-control-plane \
  --query 'Configuration.[Runtime,MemorySize,Timeout]'
```

Expected output: `["python3.11", 256, 60]`

### Step 5: Deploy Glue Job Script

#### 5.1 Upload Glue Script to S3

```bash
aws s3 cp glue_streaming_job.py \
  s3://${MANIFEST_BUCKET}/scripts/glue_streaming_job.py

# Verify upload
aws s3 ls s3://${MANIFEST_BUCKET}/scripts/
```

Expected output: `glue_streaming_job.py`

#### 5.2 Verify Glue Job Configuration

```bash
aws glue get-job \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --query 'Job.[Name,Role,Command.Name,WorkerType,NumberOfWorkers]'
```

Expected output: `["ndjson-parquet-sqs-streaming-processor", "...", "gluestreaming", "G.2X", 10]`

### Step 6: Start Glue Streaming Job

#### 6.1 Start the Job

```bash
# Start streaming job (runs 24/7)
JOB_RUN_ID=$(aws glue start-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --query 'JobRunId' \
  --output text)

echo "Job Run ID: $JOB_RUN_ID"
```

#### 6.2 Monitor Job Startup

```bash
# Check job status (should be RUNNING)
aws glue get-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --run-id $JOB_RUN_ID \
  --query 'JobRun.[JobRunState,StartedOn,ExecutionTime]'
```

Expected: `["RUNNING", "2025-12-21T...", 0]`

#### 6.3 Monitor Job Logs

```bash
# Watch continuous logs
aws logs tail /aws-glue/jobs/output --follow

# Or check for errors
aws logs tail /aws-glue/jobs/error --since 5m
```

### Step 7: Verify Pipeline Configuration

#### 7.1 Check SQS Queue

```bash
QUEUE_URL=$(aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].Outputs[?OutputKey==`SQSQueueURL`].OutputValue' \
  --output text)

aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names All
```

Verify:
- `VisibilityTimeout`: 900
- `MessageRetentionPeriod`: 1209600
- `ReceiveMessageWaitTimeSeconds`: 20

#### 7.2 Check Lambda Event Source Mapping

```bash
aws lambda list-event-source-mappings \
  --function-name ndjson-parquet-sqs-manifest-builder
```

Verify:
- `State`: "Enabled"
- `BatchSize`: 10
- `MaximumBatchingWindowInSeconds`: 30

#### 7.3 Check EventBridge Rule

```bash
aws events describe-rule \
  --name ndjson-parquet-sqs-glue-state-change
```

Verify:
- `State`: "ENABLED"

#### 7.4 Check DynamoDB Tables

```bash
# File tracking table
aws dynamodb describe-table \
  --table-name ndjson-parquet-sqs-file-tracking \
  --query 'Table.[TableName,BillingModeSummary.BillingMode,TableStatus]'

# Metrics table
aws dynamodb describe-table \
  --table-name ndjson-parquet-sqs-metrics \
  --query 'Table.[TableName,BillingModeSummary.BillingMode,TableStatus]'
```

Expected: `["table-name", "PAY_PER_REQUEST", "ACTIVE"]`

### Step 8: Test with Sample Data

#### 8.1 Generate Test Files

```bash
# Create test data directory
mkdir -p /tmp/test-files

# Generate 10 test files (3.5MB each)
for i in {1..10}; do
  python3 << EOF
import json
from datetime import datetime

# Generate ~3.5MB of NDJSON data
with open('/tmp/test-files/2025-12-21-test$(printf "%04d" $i).ndjson', 'w') as f:
    for j in range(5000):  # Adjust to get ~3.5MB
        record = {
            'id': f'rec_{$i}_{j}',
            'timestamp': datetime.utcnow().isoformat(),
            'data': 'x' * 700  # Pad to reach target size
        }
        f.write(json.dumps(record) + '\n')
EOF
done

# Verify file sizes
ls -lh /tmp/test-files/
```

#### 8.2 Upload Test Files

```bash
INPUT_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].Outputs[?OutputKey==`InputBucketName`].OutputValue' \
  --output text)

# Upload files
aws s3 sync /tmp/test-files/ s3://${INPUT_BUCKET}/

echo "Uploaded files to s3://${INPUT_BUCKET}/"
```

#### 8.3 Monitor Processing

**Check SQS Queue:**
```bash
aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible

# Should show messages being processed
```

**Check Lambda Invocations:**
```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=ndjson-parquet-sqs-manifest-builder \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Sum
```

**Check DynamoDB:**
```bash
aws dynamodb query \
  --table-name ndjson-parquet-sqs-file-tracking \
  --key-condition-expression "date_prefix = :date" \
  --expression-attribute-values '{":date":{"S":"2025-12-21"}}' \
  --limit 5
```

**Check Manifest Creation:**
```bash
aws s3 ls s3://${MANIFEST_BUCKET}/manifests/2025-12-21/
```

**Check Output:**
```bash
OUTPUT_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].Outputs[?OutputKey==`OutputBucketName`].OutputValue' \
  --output text)

# Wait a few minutes, then check for output
aws s3 ls s3://${OUTPUT_BUCKET}/merged-parquet-2025-12-21/
```

### Step 9: Configure CloudWatch Dashboard

#### 9.1 Access Dashboard

```bash
DASHBOARD_URL=$(aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].Outputs[?OutputKey==`DashboardURL`].OutputValue' \
  --output text)

echo "Dashboard URL: $DASHBOARD_URL"
```

Open in browser to view metrics.

#### 9.2 Add Custom Widgets (Optional)

Go to CloudWatch console and add:
- Cost tracking widget
- File processing rate
- Glue job efficiency

### Step 10: Set Up Alarms

All alarms are pre-configured! Verify:

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix ndjson-parquet-sqs
```

Expected alarms:
1. `ndjson-parquet-sqs-sqs-dlq-messages`
2. `ndjson-parquet-sqs-manifest-builder-errors`
3. `ndjson-parquet-sqs-glue-job-failure`

## 🔐 Security Hardening

### Enable S3 Access Logging

```bash
# Create logging bucket
aws s3 mb s3://${INPUT_BUCKET}-logs

# Enable logging
aws s3api put-bucket-logging \
  --bucket $INPUT_BUCKET \
  --bucket-logging-status '{
    "LoggingEnabled": {
      "TargetBucket": "'${INPUT_BUCKET}'-logs",
      "TargetPrefix": "input-bucket-logs/"
    }
  }'
```

### Enable CloudTrail

```bash
aws cloudtrail create-trail \
  --name ndjson-pipeline-trail \
  --s3-bucket-name <your-cloudtrail-bucket>

aws cloudtrail start-logging \
  --name ndjson-pipeline-trail
```

### Review IAM Roles

```bash
# Check Lambda roles
aws iam get-role \
  --role-name ndjson-parquet-sqs-manifest-builder-role

aws iam get-role \
  --role-name ndjson-parquet-sqs-control-plane-role

# Check Glue role
aws iam get-role \
  --role-name ndjson-parquet-sqs-glue-job-role
```

Verify principle of least privilege.

## 📊 Post-Deployment Validation

### Checklist

- [ ] CloudFormation stack: `CREATE_COMPLETE`
- [ ] SNS subscription: Confirmed
- [ ] Lambda #1: Code deployed, event source enabled
- [ ] Lambda #2: Code deployed, EventBridge rule enabled
- [ ] Glue job: Script uploaded, job running
- [ ] SQS: Queue active, DLQ configured
- [ ] DynamoDB: Tables active
- [ ] Test files: Uploaded and processed
- [ ] Manifests: Created in S3
- [ ] Parquet output: Files in output bucket
- [ ] CloudWatch: Metrics visible
- [ ] Alarms: Configured and active

### Validation Commands

```bash
# All-in-one validation script
cat > validate.sh << 'EOF'
#!/bin/bash

echo "=== Stack Status ==="
aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-sqs \
  --query 'Stacks[0].StackStatus'

echo "=== SQS Queue Depth ==="
aws sqs get-queue-attributes \
  --queue-url $QUEUE_URL \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages'

echo "=== Glue Job Status ==="
aws glue get-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --run-id $JOB_RUN_ID \
  --query 'JobRun.JobRunState'

echo "=== Recent Lambda Invocations ==="
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=ndjson-parquet-sqs-manifest-builder \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 3600 \
  --statistics Sum \
  --query 'Datapoints[0].Sum'

echo "=== Files in Tracking Table ==="
aws dynamodb scan \
  --table-name ndjson-parquet-sqs-file-tracking \
  --select COUNT \
  --query 'Count'

echo "=== Validation Complete ==="
EOF

chmod +x validate.sh
./validate.sh
```

## 🚨 Rollback Procedures

### If Deployment Fails

```bash
# Delete stack
aws cloudformation delete-stack \
  --stack-name ndjson-parquet-sqs

# Wait for deletion
aws cloudformation wait stack-delete-complete \
  --stack-name ndjson-parquet-sqs

# Clean up any remaining S3 buckets
aws s3 rb s3://${INPUT_BUCKET} --force
aws s3 rb s3://${MANIFEST_BUCKET} --force
aws s3 rb s3://${OUTPUT_BUCKET} --force
aws s3 rb s3://${QUARANTINE_BUCKET} --force
```

### If Need to Pause Pipeline

```bash
# Stop Glue job
aws glue stop-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --job-run-id $JOB_RUN_ID

# Disable Lambda event source
aws lambda update-event-source-mapping \
  --uuid <MAPPING_UUID> \
  --enabled false
```

## 📝 Next Steps

1. **Production Readiness:**
   - [ ] Set up backup and disaster recovery
   - [ ] Configure cost alerts
   - [ ] Create runbooks for common operations
   - [ ] Train team on operations

2. **Optimization:**
   - [ ] Monitor costs for 1 week
   - [ ] Adjust Glue workers based on queue depth
   - [ ] Fine-tune batch sizes
   - [ ] Review and optimize Lambda memory

3. **Documentation:**
   - [ ] Document team procedures
   - [ ] Create on-call playbooks
   - [ ] Set up knowledge base

---

**Deployment Complete!** 🎉

Your pipeline is now running and processing files. Monitor the CloudWatch dashboard and check your email for any alerts.
