#!/bin/bash

# Set Small Batch Size for Testing
# Changes MAX_BATCH_SIZE_GB to 0.001 (1MB) for testing with small files

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
LAMBDA_NAME="${STACK_NAME}-manifest-builder"

echo -e "${GREEN}Setting Small Batch Size for Testing${NC}"
echo "Lambda: $LAMBDA_NAME"
echo ""

echo -e "${YELLOW}Getting current environment variables...${NC}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Get current config to preserve all variables
CURRENT_ENV=$(aws lambda get-function-configuration \
  --function-name "$LAMBDA_NAME" \
  --region $REGION \
  --query 'Environment.Variables' \
  --output json)

echo "Current environment variables retrieved"
echo ""

echo -e "${YELLOW}Updating MAX_BATCH_SIZE_GB to 0.001 (1MB)...${NC}"

# Update only MAX_BATCH_SIZE_GB, preserve all other variables
aws lambda update-function-configuration \
  --function-name "$LAMBDA_NAME" \
  --environment "Variables={
    TRACKING_TABLE=${STACK_NAME}-file-tracking,
    METRICS_TABLE=${STACK_NAME}-metrics,
    MANIFEST_BUCKET=ndjson-manifests-${AWS_ACCOUNT_ID},
    GLUE_JOB_NAME=${STACK_NAME}-streaming-processor,
    MAX_BATCH_SIZE_GB=0.001,
    QUARANTINE_BUCKET=ndjson-quarantine,
    EXPECTED_FILE_SIZE_MB=3.5,
    SIZE_TOLERANCE_PERCENT=20,
    LOCK_TABLE=${STACK_NAME}-file-tracking,
    LOCK_TTL_SECONDS=300
  }" \
  --region $REGION

echo ""
echo -e "${GREEN}✓ Batch size updated to 0.001 GB (1MB)${NC}"
echo ""

echo "Waiting for Lambda to update (10 seconds)..."
sleep 10

echo ""
echo "Current configuration:"
aws lambda get-function-configuration \
  --function-name "$LAMBDA_NAME" \
  --region $REGION \
  --query 'Environment.Variables' \
  --output table

echo ""
echo -e "${GREEN}Configuration complete!${NC}"
echo ""
echo "Now your test files (even small ones) will trigger manifest creation."
echo ""
echo "Next steps:"
echo "  1. Upload test data: ./upload-test-data.sh"
echo "  2. Wait 1 minute for Lambda to process"
echo "  3. Check manifests: aws s3 ls s3://ndjson-manifests-804450520964/manifests/ --recursive"
echo ""
echo -e "${YELLOW}IMPORTANT: For production, change this back to 1.0 GB!${NC}"
