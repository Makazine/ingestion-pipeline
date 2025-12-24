#!/bin/bash

# Fix Quarantine Bucket Issue
# Creates the quarantine bucket or disables quarantine feature

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
LAMBDA_NAME="${STACK_NAME}-manifest-builder"
QUARANTINE_BUCKET="ndjson-quarantine-${AWS_ACCOUNT_ID}"

echo -e "${GREEN}Fixing Quarantine Bucket${NC}"
echo ""

# Option 1: Create the quarantine bucket
echo -e "${YELLOW}Option 1: Creating quarantine bucket...${NC}"
aws s3 mb "s3://${QUARANTINE_BUCKET}" --region $REGION 2>/dev/null && echo "✓ Bucket created" || echo "Bucket already exists or error occurred"

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket "${QUARANTINE_BUCKET}" \
  --versioning-configuration Status=Enabled \
  --region $REGION 2>/dev/null || true

echo ""

# Update Lambda to use the correct quarantine bucket name
echo -e "${YELLOW}Updating Lambda environment variables...${NC}"

aws lambda update-function-configuration \
  --function-name "$LAMBDA_NAME" \
  --environment "Variables={
    TRACKING_TABLE=${STACK_NAME}-file-tracking,
    METRICS_TABLE=${STACK_NAME}-metrics,
    MANIFEST_BUCKET=ndjson-manifests-${AWS_ACCOUNT_ID},
    GLUE_JOB_NAME=${STACK_NAME}-streaming-processor,
    MAX_BATCH_SIZE_GB=0.001,
    QUARANTINE_BUCKET=${QUARANTINE_BUCKET},
    EXPECTED_FILE_SIZE_MB=3.5,
    SIZE_TOLERANCE_PERCENT=20,
    LOCK_TABLE=${STACK_NAME}-file-tracking,
    LOCK_TTL_SECONDS=300
  }" \
  --region $REGION

echo ""
echo -e "${GREEN}✓ Quarantine bucket configured${NC}"
echo "Bucket: s3://${QUARANTINE_BUCKET}"
echo ""

echo "Waiting for Lambda to update (10 seconds)..."
sleep 10

echo ""
echo -e "${GREEN}Configuration complete!${NC}"
echo ""
echo "The quarantine bucket will store files that fail validation."
echo ""
