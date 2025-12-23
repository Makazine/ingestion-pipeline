# Test Data Generator Lambda - Deployment Guide

## Overview

The Test Data Generator Lambda function generates realistic NDJSON test files and uploads them directly to the S3 input bucket. This is useful for testing, load testing, and validating the NDJSON to Parquet pipeline.

## Architecture

```
┌─────────────────────────────────┐
│  Manual Invocation /            │
│  EventBridge Schedule           │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ Test Data Generator Lambda      │
│ - Generates NDJSON records      │
│ - Creates files (3.5MB default) │
│ - Uploads to S3                 │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ S3 Input Bucket                 │
│ ndjson-input-{account-id}       │
└────────────┬────────────────────┘
             │
             ▼
      [Pipeline Processing]
```

## Files Generated

### 1. IAM Configuration Files

#### [iam-test-data-generator-role.yaml](../configurations/iam-test-data-generator-role.yaml)
Standalone IAM role and policies for the Lambda function.

**Resources:**
- `TestDataGeneratorLambdaRole` - Execution role with Lambda basic execution policy
- `TestDataGeneratorS3Policy` - S3 permissions for uploading files
- `TestDataGeneratorLogsPolicy` - CloudWatch Logs permissions

**Permissions granted:**
- S3 PutObject to input bucket
- S3 ListBucket for validation
- CloudWatch Logs for function logging

#### [iam-test-data-generator-policy.json](../configurations/iam-test-data-generator-policy.json)
Standalone IAM policy in JSON format for manual attachment.

### 2. Complete Deployment Template

#### [lambda-test-data-generator-full.yaml](../configurations/lambda-test-data-generator-full.yaml)
Complete CloudFormation template including IAM role, Lambda function, and CloudWatch resources.

**Resources:**
- IAM execution role and policies
- Lambda function with configurable parameters
- CloudWatch Log Group with 7-day retention
- CloudWatch Alarms for errors and throttles
- Lambda permissions for EventBridge

**Parameters:**
- `ProjectName` - Project name prefix (default: `ndjson-parquet`)
- `InputBucketName` - S3 input bucket name
- `LambdaCodeS3Bucket` - Bucket containing deployment package
- `LambdaCodeS3Key` - S3 key for deployment package
- `TargetFileSizeMB` - Target file size (default: 3.5 MB)
- `FilesPerInvocation` - Files per invocation (default: 10)
- `LambdaTimeout` - Function timeout (default: 300 seconds)
- `LambdaMemorySize` - Memory allocation (default: 512 MB)

### 3. Deployment Resources

#### [parameters-test-data-generator.json](../configurations/parameters-test-data-generator.json)
CloudFormation parameter values for deployment.

#### [deploy-test-data-generator.sh](../deploy-test-data-generator.sh)
Automated deployment script.

**What it does:**
1. Validates prerequisites (files, AWS credentials)
2. Packages Lambda function into ZIP
3. Uploads deployment package to S3
4. Validates CloudFormation template
5. Creates/updates CloudFormation stack
6. Waits for deployment completion
7. Displays stack outputs
8. Optionally tests the function

## Deployment Instructions

### Prerequisites

1. **AWS CLI** installed and configured
2. **jq** installed (for JSON parsing)
3. **zip** command available
4. AWS credentials with permissions to:
   - Create/update CloudFormation stacks
   - Create IAM roles and policies
   - Create Lambda functions
   - Upload to S3
   - Create CloudWatch resources

### Step 1: Update Parameters

Edit [parameters-test-data-generator.json](../configurations/parameters-test-data-generator.json):

```json
[
  {
    "ParameterKey": "InputBucketName",
    "ParameterValue": "ndjson-input-YOUR-ACCOUNT-ID"
  },
  {
    "ParameterKey": "LambdaCodeS3Bucket",
    "ParameterValue": "your-lambda-code-bucket"
  }
]
```

### Step 2: Run Deployment Script

```bash
# Make script executable
chmod +x deploy-test-data-generator.sh

# Run deployment
./deploy-test-data-generator.sh
```

The script will:
- Package the Lambda function
- Upload to S3
- Deploy CloudFormation stack
- Optionally test the function

### Step 3: Verify Deployment

Check the CloudFormation stack:

```bash
aws cloudformation describe-stacks \
  --stack-name ndjson-parquet-test-data-generator \
  --query 'Stacks[0].Outputs'
```

## Usage

### Manual Invocation

#### Basic Test (Default: 10 files, 3.5MB each)
```bash
aws lambda invoke \
  --function-name ndjson-parquet-test-data-generator \
  --payload '{}' \
  response.json && cat response.json | jq .
```

#### Generate 5 Files
```bash
aws lambda invoke \
  --function-name ndjson-parquet-test-data-generator \
  --payload '{"file_count": 5}' \
  response.json && cat response.json | jq .
```

#### Generate Files for Specific Date
```bash
aws lambda invoke \
  --function-name ndjson-parquet-test-data-generator \
  --payload '{"file_count": 20, "date_prefix": "2025-12-20"}' \
  response.json && cat response.json | jq .
```

#### Generate Custom Size Files
```bash
aws lambda invoke \
  --function-name ndjson-parquet-test-data-generator \
  --payload '{"file_count": 10, "target_size_mb": 5.0}' \
  response.json && cat response.json | jq .
```

#### Large Load Test (100 files)
```bash
aws lambda invoke \
  --function-name ndjson-parquet-test-data-generator \
  --payload '{"file_count": 100, "target_size_mb": 3.5}' \
  response.json && cat response.json | jq .
```

### Event Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `file_count` | number | 10 | Number of files to generate |
| `date_prefix` | string | today | Date prefix for filenames (yyyy-mm-dd) |
| `target_size_mb` | number | 3.5 | Target file size in MB |

### Response Format

**Success Response:**
```json
{
  "statusCode": 200,
  "body": {
    "status": "completed",
    "total_files": 5,
    "successful": 5,
    "failed": 0,
    "total_size_mb": 17.5,
    "average_size_mb": 3.5,
    "bucket": "ndjson-input-804450520964",
    "date_prefix": "2025-12-23",
    "files": [
      {
        "status": "success",
        "bucket": "ndjson-input-804450520964",
        "key": "2025-12-23-test0000-143052.ndjson",
        "size_bytes": 3670016,
        "size_mb": 3.5,
        "s3_uri": "s3://ndjson-input-804450520964/2025-12-23-test0000-143052.ndjson"
      }
    ]
  }
}
```

**Error Response:**
```json
{
  "statusCode": 500,
  "body": {
    "status": "error",
    "error": "Error message here"
  }
}
```

## Automated Generation (Optional)

### Set Up EventBridge Schedule

Generate 10 files every hour:

```bash
# Create EventBridge rule
aws events put-rule \
  --name test-data-generator-hourly \
  --schedule-expression "rate(1 hour)" \
  --state ENABLED

# Add Lambda target
aws events put-targets \
  --rule test-data-generator-hourly \
  --targets "Id=1,Arn=arn:aws:lambda:REGION:ACCOUNT:function:ndjson-parquet-test-data-generator,Input={\"file_count\":10}"

# Add permission for EventBridge to invoke Lambda
aws lambda add-permission \
  --function-name ndjson-parquet-test-data-generator \
  --statement-id AllowEventBridgeInvoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn arn:aws:events:REGION:ACCOUNT:rule/test-data-generator-hourly
```

### CloudFormation EventBridge Rule

Add to your template:

```yaml
TestDataSchedule:
  Type: AWS::Events::Rule
  Properties:
    Name: test-data-generator-schedule
    Description: Generate test data every hour
    ScheduleExpression: rate(1 hour)
    State: ENABLED
    Targets:
      - Arn: !GetAtt TestDataGeneratorFunction.Arn
        Id: TestDataGeneratorTarget
        Input: '{"file_count": 10, "target_size_mb": 3.5}'
```

## Monitoring

### CloudWatch Logs

View function logs:

```bash
aws logs tail /aws/lambda/ndjson-parquet-test-data-generator --follow
```

### CloudWatch Metrics

Key metrics to monitor:
- **Invocations** - Number of times function is called
- **Duration** - Execution time
- **Errors** - Failed invocations
- **Throttles** - Rate limit hits

View metrics in AWS Console:
```
CloudWatch > Metrics > Lambda > By Function Name
```

### CloudWatch Alarms

The deployment includes two alarms:

1. **Error Alarm** - Triggers when >5 errors in 5 minutes
2. **Throttle Alarm** - Triggers when any throttling occurs

View alarms:
```bash
aws cloudwatch describe-alarms --alarm-name-prefix ndjson-parquet-test-data-generator
```

## Generated File Format

### Filename Pattern
```
{date_prefix}-test{sequence:04d}-{timestamp}.ndjson
```

Example: `2025-12-23-test0000-143052.ndjson`

### Record Schema

Each NDJSON record contains:

```json
{
  "id": "evt_20251223143052_000001",
  "timestamp": "2025-12-23T14:30:52.123456Z",
  "event_type": "page_view",
  "user_id": "user_1234",
  "session_id": "a1b2c3d4...",
  "ip_address": "192.168.1.1",
  "user_agent": "Mozilla/5.0...",
  "country": "US",
  "city": "New York",
  "latitude": 40.7128,
  "longitude": -74.0060,
  "device_type": "desktop",
  "os": "Windows",
  "browser": "Chrome",
  "page_url": "https://example.com/...",
  "referrer": "https://referrer.com/...",
  "utm_source": "google",
  "utm_medium": "cpc",
  "utm_campaign": "campaign_42",
  "duration_seconds": 120,
  "bounce": false,
  "conversion": true,
  "revenue": 49.99,
  "items_viewed": 5,
  "custom_data": {
    "experiment_id": "exp_12",
    "variant": "A",
    "feature_flags": {
      "feature_1": true,
      "feature_2": false
    }
  },
  "padding": "random_string..."
}
```

### File Metadata

S3 object metadata includes:
- `generator`: `test-data-lambda`
- `date_prefix`: Date prefix used
- `record_count`: Number of records in file
- `file_size_mb`: File size in MB

View metadata:
```bash
aws s3api head-object \
  --bucket ndjson-input-804450520964 \
  --key 2025-12-23-test0000-143052.ndjson
```

## Cost Estimation

### Lambda Costs

Assumptions:
- 512 MB memory
- 30 seconds average execution time
- 10 files per invocation
- 100 invocations per month

**Monthly cost:** ~$0.10 - $0.20

### S3 Costs

Assumptions:
- 10 files × 3.5 MB = 35 MB per invocation
- 100 invocations = 3.5 GB/month
- Files processed and deleted within days

**Monthly cost:** ~$0.08 (storage) + $0.01 (requests) = ~$0.09

**Total estimated monthly cost:** ~$0.20 - $0.30

## Troubleshooting

### Issue: Lambda timeout

**Symptom:** Function times out before completing all files

**Solution:**
- Reduce `file_count` parameter
- Increase `LambdaTimeout` in CloudFormation
- Increase `LambdaMemorySize` for faster execution

### Issue: S3 access denied

**Symptom:** Error uploading files to S3

**Solution:**
- Verify IAM role has `s3:PutObject` permission
- Check bucket name in parameters matches actual bucket
- Verify bucket exists and is accessible

### Issue: Out of memory

**Symptom:** Lambda runs out of memory

**Solution:**
- Reduce `target_size_mb` parameter
- Reduce `file_count` parameter
- Increase `LambdaMemorySize` in CloudFormation

### Issue: No files generated

**Symptom:** Function completes but no files in S3

**Solution:**
- Check CloudWatch logs for errors
- Verify `INPUT_BUCKET` environment variable
- Test with minimal payload: `{"file_count": 1, "target_size_mb": 1}`

## Cleanup

### Delete Lambda and IAM Role

```bash
aws cloudformation delete-stack \
  --stack-name ndjson-parquet-test-data-generator

aws cloudformation wait stack-delete-complete \
  --stack-name ndjson-parquet-test-data-generator
```

### Delete Generated Test Files

```bash
# List test files
aws s3 ls s3://ndjson-input-804450520964/ | grep test

# Delete all test files
aws s3 rm s3://ndjson-input-804450520964/ \
  --recursive \
  --exclude "*" \
  --include "*-test*.ndjson"
```

### Delete Lambda Deployment Package

```bash
aws s3 rm s3://your-code-bucket/lambda/test-data-generator.zip
```

## Integration with Pipeline

Once deployed, the test data generator integrates seamlessly with the existing NDJSON to Parquet pipeline:

1. **Lambda generates files** → S3 input bucket
2. **S3 Event Notification** → Manifest Builder Queue
3. **Manifest Builder Lambda** → Creates manifest
4. **Control Plane Lambda** → Triggers Glue job
5. **Glue Streaming Job** → Processes to Parquet
6. **Parquet files** → Output bucket

## Best Practices

1. **Start small** - Test with 1-2 files before large batches
2. **Monitor costs** - Watch CloudWatch metrics and S3 storage
3. **Use date prefixes** - Organize test data by date
4. **Clean up regularly** - Delete old test files to save costs
5. **Set alarms** - Monitor errors and throttles
6. **Version control** - Keep Lambda code in git
7. **Test in dev** - Validate changes in dev environment first

## Support

For issues or questions:
- Check CloudWatch Logs for detailed error messages
- Review [DEPLOYMENT-GUIDE.md](DEPLOYMENT-GUIDE.md) for pipeline deployment
- Consult [DLQ-ANALYSIS.md](DLQ-ANALYSIS.md) if files fail processing
