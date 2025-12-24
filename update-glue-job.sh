#!/bin/bash

# Update Glue Streaming Job Script
# Uploads the latest glue_streaming_job.py to S3

set -e

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DEPLOYMENT_BUCKET="ndjson-parquet-deployment-${AWS_ACCOUNT_ID}"
GLUE_SCRIPT="app/glue_streaming_job.py"
JOB_NAME="${STACK_NAME}-streaming-processor"

echo -e "${GREEN}Updating Glue Streaming Job Script${NC}"
echo "AWS Account: $AWS_ACCOUNT_ID"
echo "Region: $REGION"
echo ""

# Verify the script exists
if [ ! -f "$GLUE_SCRIPT" ]; then
    echo "Error: Glue script not found at $GLUE_SCRIPT"
    exit 1
fi

# Upload Glue script to deployment bucket
echo -e "${YELLOW}Uploading Glue script to S3...${NC}"
aws s3 cp "$GLUE_SCRIPT" "s3://${DEPLOYMENT_BUCKET}/scripts/glue_streaming_job.py" --region $REGION

echo -e "${GREEN}✓ Glue script uploaded to s3://${DEPLOYMENT_BUCKET}/scripts/glue_streaming_job.py${NC}"
echo ""

# Get current job configuration and save to temp file
echo -e "${YELLOW}Retrieving current job configuration...${NC}"

# Create temp directory in current location (works on both Windows and Unix)
TEMP_DIR="./build/temp"
mkdir -p "$TEMP_DIR"

aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --output json > "${TEMP_DIR}/glue-job-config.json"

GLUE_ROLE=$(jq -r '.Job.Role' "${TEMP_DIR}/glue-job-config.json")

if [ -z "$GLUE_ROLE" ] || [ "$GLUE_ROLE" == "null" ]; then
    echo "Error: Could not retrieve Glue job role"
    exit 1
fi

echo "Found Glue role: $GLUE_ROLE"

# Extract and update the job configuration
echo -e "${YELLOW}Preparing job update...${NC}"

# Create job update JSON with all existing settings but updated script location and command type
# Build object conditionally to avoid null values
jq --arg role "$GLUE_ROLE" \
   --arg script "s3://${DEPLOYMENT_BUCKET}/scripts/glue_streaming_job.py" \
   '.Job |
   {
     Role: $role,
     Command: {
       Name: "glueetl",
       ScriptLocation: $script,
       PythonVersion: "3"
     }
   } +
   (if .DefaultArguments then {DefaultArguments: .DefaultArguments} else {} end) +
   (if .MaxRetries then {MaxRetries: .MaxRetries} else {} end) +
   (if .Timeout then {Timeout: .Timeout} else {} end) +
   (if .WorkerType then {WorkerType: .WorkerType} else {} end) +
   (if .NumberOfWorkers then {NumberOfWorkers: .NumberOfWorkers} else {} end) +
   (if .GlueVersion then {GlueVersion: .GlueVersion} else {} end) +
   (if .ExecutionProperty then {ExecutionProperty: .ExecutionProperty} else {} end)
   ' "${TEMP_DIR}/glue-job-config.json" > "${TEMP_DIR}/glue-job-update.json"

echo ""
echo "DefaultArguments from current job:"
jq -r '.Job.DefaultArguments' "${TEMP_DIR}/glue-job-config.json"
echo ""

echo "Job update configuration:"
cat "${TEMP_DIR}/glue-job-update.json"
echo ""

# Update the Glue job
echo -e "${YELLOW}Updating Glue job...${NC}"
aws glue update-job \
  --job-name "$JOB_NAME" \
  --job-update "file://${TEMP_DIR}/glue-job-update.json" \
  --region $REGION > /dev/null

# Clean up temp files
rm -f "${TEMP_DIR}/glue-job-config.json" "${TEMP_DIR}/glue-job-update.json"

echo -e "${GREEN}✓ Glue job updated${NC}"
echo ""

# Display job details
echo -e "${YELLOW}Current Glue Job Configuration:${NC}"
aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query 'Job.{Name:Name,ScriptLocation:Command.ScriptLocation,Status:ExecutionProperty,WorkerType:WorkerType,NumberOfWorkers:NumberOfWorkers}' \
  --output table

echo ""
echo -e "${GREEN}Glue job update completed successfully!${NC}"
echo ""
echo "Next steps:"
echo "  1. Check job configuration: aws glue get-job --job-name $JOB_NAME --region $REGION"
echo "  2. Start job run: aws glue start-job-run --job-name $JOB_NAME --region $REGION"
echo "  3. View job logs: aws logs tail /aws-glue/jobs/output --follow"
echo ""
