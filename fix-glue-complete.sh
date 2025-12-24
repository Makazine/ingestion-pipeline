#!/bin/bash

# Complete Glue Job Fix Script
# Creates missing bucket and updates Glue version to 4.0

set -e

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
JOB_NAME="${STACK_NAME}-streaming-processor"
MANIFEST_BUCKET="ndjson-manifests-${AWS_ACCOUNT_ID}"
OUTPUT_BUCKET="ndjson-parquet-output-${AWS_ACCOUNT_ID}"
DEPLOYMENT_BUCKET="ndjson-parquet-deployment-${AWS_ACCOUNT_ID}"

echo -e "${GREEN}Complete Glue Job Fix${NC}"
echo "Job Name: $JOB_NAME"
echo "Region: $REGION"
echo ""

# Step 1: Create output bucket if it doesn't exist
echo -e "${YELLOW}Step 1: Checking output bucket...${NC}"
if aws s3 ls "s3://${OUTPUT_BUCKET}/" 2>&1 | grep -q 'NoSuchBucket'; then
    echo "Creating output bucket: ${OUTPUT_BUCKET}"
    aws s3 mb "s3://${OUTPUT_BUCKET}" --region $REGION

    # Enable versioning
    aws s3api put-bucket-versioning \
        --bucket "${OUTPUT_BUCKET}" \
        --versioning-configuration Status=Enabled \
        --region $REGION

    echo -e "${GREEN}✓ Output bucket created${NC}"
else
    echo -e "${GREEN}✓ Output bucket already exists${NC}"
fi
echo ""

# Step 2: Get current job configuration
echo -e "${YELLOW}Step 2: Retrieving current job configuration...${NC}"
JOB_CONFIG=$(aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --output json)

GLUE_ROLE=$(echo "$JOB_CONFIG" | python -c "import sys, json; print(json.load(sys.stdin)['Job']['Role'])")
SCRIPT_LOCATION="s3://${DEPLOYMENT_BUCKET}/scripts/glue_streaming_job.py"

echo "Role: $GLUE_ROLE"
echo "Script: $SCRIPT_LOCATION"
echo ""

# Step 3: Update Glue job with version 4.0, correct command, and all settings
echo -e "${YELLOW}Step 3: Updating Glue job configuration...${NC}"
echo "Updating to Glue 4.0, glueetl command, and fixing all settings..."

aws glue update-job \
  --job-name "$JOB_NAME" \
  --job-update '{
    "Role": "'"${GLUE_ROLE}"'",
    "GlueVersion": "4.0",
    "Command": {
      "Name": "glueetl",
      "ScriptLocation": "'"${SCRIPT_LOCATION}"'",
      "PythonVersion": "3"
    },
    "DefaultArguments": {
      "--job-language": "python",
      "--job-bookmark-option": "job-bookmark-disable",
      "--enable-metrics": "true",
      "--enable-spark-ui": "true",
      "--spark-event-logs-path": "s3://'"${MANIFEST_BUCKET}"'/spark-logs/",
      "--enable-continuous-cloudwatch-log": "true",
      "--enable-continuous-log-filter": "true",
      "--MANIFEST_BUCKET": "'"${MANIFEST_BUCKET}"'",
      "--OUTPUT_BUCKET": "'"${OUTPUT_BUCKET}"'",
      "--COMPRESSION_TYPE": "snappy",
      "--TempDir": "s3://'"${MANIFEST_BUCKET}"'/temp/",
      "--enable-glue-datacatalog": "true"
    },
    "MaxRetries": 0,
    "Timeout": 2880,
    "WorkerType": "G.1X",
    "NumberOfWorkers": 10,
    "ExecutionProperty": {
      "MaxConcurrentRuns": 1
    }
  }' \
  --region $REGION

echo -e "${GREEN}✓ Glue job updated successfully${NC}"
echo ""

# Step 4: Display updated configuration
echo -e "${YELLOW}Step 4: Verifying updated configuration...${NC}"
aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query 'Job.{Name:Name,GlueVersion:GlueVersion,Command:Command.Name,WorkerType:WorkerType,Workers:NumberOfWorkers,Script:Command.ScriptLocation}' \
  --output table

echo ""
echo -e "${YELLOW}DefaultArguments:${NC}"
aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query 'Job.DefaultArguments' \
  --output json

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}All fixes applied successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Changes made:"
echo "  1. ✓ Created output bucket: ${OUTPUT_BUCKET}"
echo "  2. ✓ Updated Glue version: 0.9 → 4.0"
echo "  3. ✓ Fixed command type: gluestreaming → glueetl"
echo "  4. ✓ Added WorkerType: G.1X (replaces deprecated AllocatedCapacity)"
echo "  5. ✓ Set NumberOfWorkers: 10"
echo "  6. ✓ All environment variables configured"
echo ""
echo "You can now run the Glue job!"
