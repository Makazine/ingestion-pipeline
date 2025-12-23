# CloudFormation Addition: Test Data Generator Lambda

## Add to Your CloudFormation Template

Add this to the **Resources** section of `cloudformation-sqs-manifest.yaml`:

```yaml
  # ==================== TEST DATA GENERATOR (OPTIONAL) ====================
  
  TestDataGeneratorRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${ProjectName}-test-data-generator-role'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: TestDataGeneratorPermissions
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              # Write to input bucket
              - Effect: Allow
                Action:
                  - s3:PutObject
                  - s3:PutObjectAcl
                Resource:
                  - !GetAtt InputBucket.Arn
                  - !Sub '${InputBucket.Arn}/*'

  TestDataGeneratorFunction:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: !Sub '${ProjectName}-test-data-generator'
      Runtime: python3.11
      Handler: index.lambda_handler
      Role: !GetAtt TestDataGeneratorRole.Arn
      Timeout: 900  # 15 minutes (for generating many files)
      MemorySize: 1024
      Environment:
        Variables:
          INPUT_BUCKET: !Ref InputBucket
          TARGET_FILE_SIZE_MB: '3.5'
          FILES_PER_INVOCATION: '10'
      Code:
        ZipFile: |
          # Placeholder - upload lambda_test_data_generator.py
          import json
          def lambda_handler(event, context):
              return {'statusCode': 200, 'body': json.dumps('Upload actual code')}
      Tags:
        - Key: Project
          Value: !Ref ProjectName
        - Key: Purpose
          Value: Testing

# Add to Outputs section:
Outputs:
  # ... existing outputs ...
  
  TestDataGeneratorFunctionName:
    Description: Test data generator Lambda function name
    Value: !Ref TestDataGeneratorFunction
    Export:
      Name: !Sub '${ProjectName}-test-generator'
```

## Deployment Instructions

### 1. Update CloudFormation Stack

```bash
# Update stack to add test data generator
aws cloudformation update-stack \
  --stack-name ndjson-parquet-sqs \
  --template-body file://cloudformation-sqs-manifest.yaml \
  --parameters file://parameters.json \
  --capabilities CAPABILITY_NAMED_IAM
```

### 2. Upload Lambda Code

```bash
# Package Lambda function
cd lambda/
zip test-data-generator.zip lambda_test_data_generator.py

# Upload to Lambda
aws lambda update-function-code \
  --function-name ndjson-parquet-sqs-test-data-generator \
  --zip-file fileb://test-data-generator.zip
```

### 3. Test the Generator

**Generate 10 files (default):**
```bash
aws lambda invoke \
  --function-name ndjson-parquet-sqs-test-data-generator \
  --payload '{}' \
  response.json

cat response.json | jq '.'
```

**Generate 100 files:**
```bash
aws lambda invoke \
  --function-name ndjson-parquet-sqs-test-data-generator \
  --payload '{"file_count": 100}' \
  response.json
```

**Generate files for specific date:**
```bash
aws lambda invoke \
  --function-name ndjson-parquet-sqs-test-data-generator \
  --payload '{"file_count": 50, "date_prefix": "2025-12-20"}' \
  response.json
```

**Generate custom size files (5MB):**
```bash
aws lambda invoke \
  --function-name ndjson-parquet-sqs-test-data-generator \
  --payload '{"file_count": 10, "target_size_mb": 5.0}' \
  response.json
```

### 4. Load Testing

**Generate 1000 files for load testing:**
```bash
# Invoke multiple times in parallel
for i in {1..10}; do
  aws lambda invoke \
    --function-name ndjson-parquet-sqs-test-data-generator \
    --payload '{"file_count": 100}' \
    --invocation-type Event \
    response-$i.json &
done

wait
echo "Generated 1000 test files!"
```

**Monitor processing:**
```bash
# Watch SQS queue
watch -n 5 'aws sqs get-queue-attributes \
  --queue-url <QUEUE_URL> \
  --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible'

# Watch Lambda invocations
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=ndjson-parquet-sqs-manifest-builder \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Sum
```

## Usage Examples

### Example 1: Daily Testing

```bash
# Generate test data every day
aws events put-rule \
  --name daily-test-data-generation \
  --schedule-expression "cron(0 2 * * ? *)"  # 2 AM UTC daily

aws events put-targets \
  --rule daily-test-data-generation \
  --targets "Id"="1","Arn"="<LAMBDA_ARN>","Input"='{"file_count":100}'
```

### Example 2: Continuous Load Test

```python
# Script to generate continuous load
import boto3
import time

lambda_client = boto3.client('lambda')

for hour in range(24):
    # Generate 200 files per hour (simulate production)
    for batch in range(20):
        lambda_client.invoke(
            FunctionName='ndjson-parquet-sqs-test-data-generator',
            InvocationType='Event',
            Payload='{"file_count": 10}'
        )
        time.sleep(180)  # Wait 3 minutes between batches
```

### Example 3: Validate Pipeline End-to-End

```bash
# 1. Generate test files
aws lambda invoke \
  --function-name ndjson-parquet-sqs-test-data-generator \
  --payload '{"file_count": 300, "date_prefix": "2025-12-21"}' \
  response.json

# 2. Wait for processing (5-10 minutes)
sleep 600

# 3. Verify files in DynamoDB
aws dynamodb query \
  --table-name ndjson-parquet-sqs-file-tracking \
  --key-condition-expression "date_prefix = :date" \
  --expression-attribute-values '{":date":{"S":"2025-12-21"}}' \
  --select COUNT

# 4. Verify Parquet output
aws s3 ls s3://<OUTPUT_BUCKET>/merged-parquet-2025-12-21/

# 5. Check metrics
aws dynamodb scan \
  --table-name ndjson-parquet-sqs-metrics \
  --filter-expression "metric_date = :date" \
  --expression-attribute-values '{":date":{"S":"2025-12-21"}}'
```

## Test Data Characteristics

The generator creates **realistic** test data with:

### Record Structure
```json
{
  "id": "evt_20251221103045_000123",
  "timestamp": "2025-12-21T10:30:45.123456Z",
  "event_type": "page_view",
  "user_id": "user_5432",
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
  "page_url": "https://example.com/abc123",
  "referrer": "https://referrer.com/xyz",
  "utm_source": "google",
  "utm_medium": "cpc",
  "utm_campaign": "campaign_42",
  "duration_seconds": 1234,
  "bounce": false,
  "conversion": true,
  "revenue": 99.99,
  "items_viewed": 5,
  "custom_data": {
    "experiment_id": "exp_10",
    "variant": "A",
    "feature_flags": {
      "feature_1": true,
      "feature_2": false
    }
  },
  "padding": "random_string_100_chars..."
}
```

### Characteristics
- **Realistic fields** - Mimics actual web analytics data
- **Varied data** - Random users, locations, events
- **Consistent size** - ~700 bytes per record → ~5,000 records = 3.5MB
- **Valid JSON** - All records are properly formatted
- **Timestamp variation** - Random timestamps within last hour

## Cost of Test Data Generation

```
Lambda executions:
- 1000 files = 100 invocations (10 files each)
- 100 × $0.20/million = $0.00002
- Essentially FREE!

S3 storage:
- 1000 files × 3.5MB = 3.5GB
- 3.5GB × $0.023/GB = $0.08
- VERY CHEAP!

Total cost for 1000 test files: < $0.10
```

## Cleanup Test Data

```bash
# Delete test files after testing
aws s3 rm s3://<INPUT_BUCKET>/ \
  --recursive \
  --exclude "*" \
  --include "*test*.ndjson"

# Or delete specific date
aws s3 rm s3://<INPUT_BUCKET>/ \
  --recursive \
  --exclude "*" \
  --include "2025-12-21-test*.ndjson"
```

## Troubleshooting

### Issue: Files not 3.5MB

**Check:**
```python
# Adjust records count in generator
estimated_records = self.target_size_bytes // 700  # Change 700 if needed
```

### Issue: Lambda timeout

**Solution:**
```bash
# Increase timeout for large file counts
aws lambda update-function-configuration \
  --function-name ndjson-parquet-sqs-test-data-generator \
  --timeout 900  # 15 minutes
```

### Issue: Out of memory

**Solution:**
```bash
# Increase memory
aws lambda update-function-configuration \
  --function-name ndjson-parquet-sqs-test-data-generator \
  --memory-size 2048  # 2GB
```

## Best Practices

1. **Tag test files** - Naming includes "test" for easy identification
2. **Use separate date** - Generate with past/future dates to avoid mixing with prod
3. **Cleanup regularly** - Delete test data after validation
4. **Monitor costs** - Though minimal, track S3 storage
5. **Realistic data** - Generator creates realistic patterns for accurate testing

## Summary

The test data generator provides:
✅ **Easy testing** - Generate files on-demand  
✅ **Realistic data** - Mimics production patterns  
✅ **Consistent sizing** - Always 3.5MB files  
✅ **Cost-effective** - < $0.10 per 1000 files  
✅ **Flexible** - Configurable count, size, date  
✅ **Automated** - Can schedule or script  

**Perfect for validating your pipeline!** 🎉
