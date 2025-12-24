# AWS Cost Optimization Guide

## 🚨 Immediate Actions (Do These NOW!)

### 1. Stop All Running Glue Jobs
```bash
./stop-all-glue-jobs.sh
```
**Savings: $4.40/hour → $0**

### 2. Optimize Glue Job Configuration
```bash
chmod +x optimize-glue-cost.sh
./optimize-glue-cost.sh
```
**Savings: 10 workers → 2 workers = 80% reduction ($4.40/hr → $0.88/hr)**

### 3. Check Current Costs
```bash
aws ce get-cost-and-usage \
  --time-period Start=2025-12-01,End=2025-12-24 \
  --granularity DAILY \
  --metrics BlendedCost \
  --group-by Type=SERVICE \
  --region us-east-1 \
  --query 'ResultsByTime[*].[TimePeriod.Start,Groups[?Keys[0]==`AWS Glue`].Metrics.BlendedCost.Amount]' \
  --output table
```

---

## 💰 Cost Breakdown Analysis

### Why You Spent $350

| Service | Configuration | Cost/Hour | Hours | Total |
|---------|---------------|-----------|-------|-------|
| **AWS Glue** | 10 G.1X workers | $4.40 | ~80 | ~$352 |
| S3 Storage | ~1-2 GB | negligible | - | <$1 |
| Lambda | Low invocations | negligible | - | <$1 |
| DynamoDB | On-demand | negligible | - | <$1 |

**Root Cause:** Glue job with 10 workers running continuously in streaming mode.

---

## 🎯 Cost Optimization Strategy

### For Development/Testing

#### Option 1: Minimal Workers (Recommended for Testing)
```bash
# 2 workers, batch mode only
Workers: 2
Cost: $0.88/hour
Monthly (if running 24/7): ~$633
```

#### Option 2: Local Development (BEST for Testing)
```bash
# Use AWS Glue Docker containers locally
# Cost: $0
```

**Setup:**
```bash
docker pull amazon/aws-glue-libs:glue_libs_4.0.0_image_01
docker run -it -v ~/.aws:/home/glue_user/.aws \
  -v $(pwd)/app:/home/glue_user/workspace \
  -e AWS_PROFILE=default \
  -p 4040:4040 -p 18080:18080 \
  amazon/aws-glue-libs:glue_libs_4.0.0_image_01 \
  /home/glue_user/workspace/glue_streaming_job.py
```

### For Production

#### Batch Processing (Not Streaming)
```bash
# Run job only when needed, triggered by Lambda
Mode: Batch (on-demand)
Workers: 2-5
Cost: Only when processing (~$0.88-2.20 per run)
```

---

## 📊 Cost-Saving Recommendations

### 1. **Use Batch Mode Instead of Streaming** ⭐⭐⭐
**Current:** Glue job runs 24/7 watching for files
**Better:** Lambda triggers Glue job only when manifests are ready

**Savings:**
- Streaming: $4.40/hr × 720 hrs/month = $3,168/month
- Batch: $4.40 × 10 runs/month = $44/month
- **Save: $3,124/month (99% reduction!)**

### 2. **Reduce Worker Count** ⭐⭐⭐
```bash
# For small datasets (< 1 GB per batch)
Workers: 2
Cost: $0.88/hour (80% savings)

# For medium datasets (1-10 GB)
Workers: 3-5
Cost: $1.32-2.20/hour
```

### 3. **Set Job Timeout Limits** ⭐⭐
```bash
# Current: 2880 minutes (48 hours!)
# Better: 60 minutes (1 hour)
Timeout: 60

# If job hangs, you only pay for 1 hour max instead of 48
```

### 4. **Use S3 Lifecycle Policies** ⭐
```bash
# Delete old Spark logs and temp files
aws s3api put-bucket-lifecycle-configuration \
  --bucket ndjson-manifests-${ACCOUNT_ID} \
  --lifecycle-configuration '{
    "Rules": [{
      "Id": "DeleteOldLogs",
      "Filter": {"Prefix": "spark-logs/"},
      "Status": "Enabled",
      "Expiration": {"Days": 7}
    },
    {
      "Id": "DeleteTempFiles",
      "Filter": {"Prefix": "temp/"},
      "Status": "Enabled",
      "Expiration": {"Days": 1}
    }]
  }'
```

### 5. **Enable Cost Allocation Tags** ⭐
```bash
aws ce create-cost-category-definition \
  --name "NDJSONProject" \
  --rules '[{
    "Value": "ndjson-pipeline",
    "Rule": {"Tags": {"Key": "Project", "Values": ["ndjson-parquet-sqs"]}}
  }]'
```

### 6. **Set Up Billing Alerts** ⭐⭐⭐
```bash
# Alert at $50
aws cloudwatch put-metric-alarm \
  --alarm-name billing-alert-50 \
  --alarm-description "Alert when charges exceed $50" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 21600 \
  --evaluation-periods 1 \
  --threshold 50 \
  --comparison-operator GreaterThanThreshold

# Alert at $100
aws cloudwatch put-metric-alarm \
  --alarm-name billing-alert-100 \
  --alarm-description "Alert when charges exceed $100" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 21600 \
  --evaluation-periods 1 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold
```

### 7. **Use AWS Budgets** ⭐⭐
```bash
# Set monthly budget of $50
aws budgets create-budget \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget '{
    "BudgetName": "NDJSON-Pipeline-Monthly",
    "BudgetLimit": {
      "Amount": "50",
      "Unit": "USD"
    },
    "TimeUnit": "MONTHLY",
    "BudgetType": "COST"
  }'
```

---

## 🔧 Testing Workflow (Cost-Optimized)

### Daily Testing Routine

```bash
# Start of day
./optimize-glue-cost.sh  # Ensure optimized config

# Test your changes
./update-glue-job.sh     # Upload new script
# Run ONE test with small data

# End of day (CRITICAL!)
./stop-all-glue-jobs.sh  # Stop all running jobs
```

### Best Practices

1. **Never run streaming mode for testing**
   - Use batch mode with specific manifest paths
   - Only run when actively testing

2. **Always stop jobs when done**
   - Don't leave jobs running overnight
   - Set calendar reminders

3. **Use small test datasets**
   - 10-100 files for testing (not 1000+)
   - Reduces processing time = less cost

4. **Monitor costs daily**
   ```bash
   aws ce get-cost-and-usage \
     --time-period Start=$(date -d '7 days ago' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
     --granularity DAILY \
     --metrics BlendedCost \
     --group-by Type=SERVICE
   ```

---

## 💡 Alternative Approaches for Learning

### 1. **AWS Free Tier** (Limited)
- Lambda: 1M requests/month free
- S3: 5 GB storage, 20K GET requests free
- DynamoDB: 25 GB storage free
- **Glue: NOT in free tier** ❌

### 2. **LocalStack / Moto** (Free)
- Mock AWS services locally
- Good for Lambda/S3/DynamoDB testing
- **Glue not fully supported** ⚠️

### 3. **Apache Spark Locally** (Free)
- Test Spark logic without Glue
- No AWS charges
- Requires local setup

```bash
# Install PySpark
pip install pyspark==3.3.0

# Run locally
spark-submit app/glue_streaming_job.py \
  --JOB_NAME test \
  --MANIFEST_BUCKET local-bucket \
  --OUTPUT_BUCKET local-output \
  --COMPRESSION_TYPE snappy
```

---

## 📈 Cost Monitoring Commands

### Check Today's Cost
```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-%d),End=$(date -d '+1 day' +%Y-%m-%d) \
  --granularity DAILY \
  --metrics BlendedCost
```

### Check This Month's Cost
```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost
```

### Check Glue Costs Specifically
```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --filter '{
    "Dimensions": {
      "Key": "SERVICE",
      "Values": ["AWS Glue"]
    }
  }'
```

---

## ⚠️ Critical Reminders

### Before Bed Each Night:
```bash
./stop-all-glue-jobs.sh
```

### Before Extended Breaks:
```bash
# Stop everything
./stop-all-glue-jobs.sh

# Verify nothing is running
aws glue get-job-runs \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --region us-east-1 \
  --query "JobRuns[?JobRunState=='RUNNING']"
```

### If Budget is Exceeded:
```bash
# Delete the stack to stop all charges
aws cloudformation delete-stack \
  --stack-name ndjson-parquet-sqs \
  --region us-east-1
```

---

## 🎯 Target Monthly Costs

| Usage Pattern | Workers | Hours/Month | Monthly Cost |
|---------------|---------|-------------|--------------|
| **Minimal Testing** | 2 | 10 | ~$9 |
| **Light Development** | 2 | 40 | ~$35 |
| **Active Development** | 2 | 100 | ~$88 |
| **Heavy Testing** | 2 | 200 | ~$176 |
| **Streaming 24/7** ⛔ | 10 | 720 | ~$3,168 |

**Recommendation for Personal Project:** Target < $50/month
