#!/bin/bash

# Quick Redeploy Script - Uses fixed template with DependsOn
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"

echo -e "${GREEN}Quick Redeploy with Fixed Template${NC}"
echo ""

# Get AWS Account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account: $AWS_ACCOUNT_ID"
echo ""

# Step 1: Delete failed stack
echo -e "${BLUE}Step 1: Deleting failed stack...${NC}"
aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION 2>/dev/null || echo "No stack to delete"
echo "Waiting for deletion..."
aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION 2>/dev/null || true
echo -e "${GREEN}✓ Stack deleted${NC}"
echo ""

# Step 1b: Delete leftover S3 buckets (have DeletionPolicy: Retain)
echo -e "${BLUE}Step 1b: Cleaning up existing S3 buckets...${NC}"
BUCKETS_TO_DELETE=(
    "ndjson-manifests-${AWS_ACCOUNT_ID}"
    "ndjson-quarantine-${AWS_ACCOUNT_ID}"
    "ndjson-parquet-sqs-logs-${AWS_ACCOUNT_ID}"
    "parquet-output-sqs-${AWS_ACCOUNT_ID}"
    "ndjson-input-sqs-${AWS_ACCOUNT_ID}"
)

for BUCKET in "${BUCKETS_TO_DELETE[@]}"; do
    if aws s3 ls "s3://${BUCKET}" --region $REGION 2>/dev/null; then
        echo "Deleting bucket: ${BUCKET}"
        aws s3 rm "s3://${BUCKET}" --recursive --region $REGION 2>/dev/null || true
        aws s3 rb "s3://${BUCKET}" --region $REGION 2>/dev/null || true
    fi
done
echo -e "${GREEN}✓ Buckets cleaned${NC}"
echo ""

# Step 1c: Delete leftover DynamoDB tables (have DeletionPolicy: Retain)
echo -e "${BLUE}Step 1c: Cleaning up existing DynamoDB tables...${NC}"
TABLES_TO_DELETE=(
    "ndjson-parquet-sqs-file-tracking"
    "ndjson-parquet-sqs-metrics"
)

for TABLE in "${TABLES_TO_DELETE[@]}"; do
    if aws dynamodb describe-table --table-name "$TABLE" --region $REGION 2>/dev/null; then
        echo "Deleting table: ${TABLE}"
        aws dynamodb delete-table --table-name "$TABLE" --region $REGION
        echo "Waiting for table deletion..."
        aws dynamodb wait table-not-exists --table-name "$TABLE" --region $REGION 2>/dev/null || sleep 5
    fi
done
echo -e "${GREEN}✓ Tables cleaned${NC}"
echo ""

# Step 2: Prepare Glue script for upload after stack creation
echo -e "${BLUE}Step 2: Preparing Glue script...${NC}"
MANIFEST_BUCKET="ndjson-manifests-${AWS_ACCOUNT_ID}"
echo "Will upload Glue script to s3://${MANIFEST_BUCKET}/scripts/ after stack creation"
echo -e "${GREEN}✓ Glue script location noted${NC}"
echo ""

# Step 3: Ensure deployment bucket has Lambda code
echo -e "${BLUE}Step 3: Preparing Lambda packages...${NC}"
DEPLOYMENT_BUCKET="ndjson-parquet-deployment-${AWS_ACCOUNT_ID}"

# Create bucket if needed
aws s3 mb "s3://${DEPLOYMENT_BUCKET}" --region $REGION 2>/dev/null || echo "Bucket already exists"

# Package and upload Lambda functions
mkdir -p build/lambda
rm -rf build/lambda/*

(cd app && zip -q ../build/lambda/manifest-builder.zip lambda_manifest_builder.py)
(cd app && zip -q ../build/lambda/control-plane.zip lambda_control_plane.py)

aws s3 cp build/lambda/manifest-builder.zip "s3://${DEPLOYMENT_BUCKET}/lambda/" --region $REGION
aws s3 cp build/lambda/control-plane.zip "s3://${DEPLOYMENT_BUCKET}/lambda/" --region $REGION

echo -e "${GREEN}✓ Lambda packages ready${NC}"
echo ""

# Step 4: Validate template
echo -e "${BLUE}Step 4: Validating fixed template...${NC}"
aws cloudformation validate-template \
    --template-body file://configurations/cloudformation-sqs-manifest.yaml \
    --region $REGION > /dev/null
echo -e "${GREEN}✓ Template is valid${NC}"
echo ""

# Step 5: Deploy stack
echo -e "${BLUE}Step 5: Deploying CloudFormation stack (this takes 5-10 min)...${NC}"

aws cloudformation create-stack \
    --stack-name $STACK_NAME \
    --template-body file://configurations/cloudformation-sqs-manifest.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags Key=Environment,Value=Production Key=Team,Value=DataEngineering \
    --region $REGION

echo "Waiting for stack creation..."
if aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION 2>&1; then
    echo -e "${GREEN}✓ Stack created successfully!${NC}"
else
    echo -e "${RED}✗ Stack creation FAILED!${NC}"
    echo ""
    aws cloudformation describe-stack-events \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]' \
        --output table
    exit 1
fi
echo ""

# Step 5b: Upload Glue script to manifest bucket (now that it exists)
echo -e "${BLUE}Step 5b: Uploading Glue script to manifest bucket...${NC}"
echo "Uploading to s3://${MANIFEST_BUCKET}/scripts/glue_streaming_job.py"
aws s3 cp app/glue_streaming_job.py "s3://${MANIFEST_BUCKET}/scripts/" --region $REGION
echo -e "${GREEN}✓ Glue script uploaded${NC}"
echo ""

# Step 6: Update Lambda functions
echo -e "${BLUE}Step 6: Updating Lambda functions...${NC}"

aws lambda update-function-code \
    --function-name "${STACK_NAME}-manifest-builder" \
    --s3-bucket "${DEPLOYMENT_BUCKET}" \
    --s3-key "lambda/manifest-builder.zip" \
    --region $REGION > /dev/null

aws lambda wait function-updated --function-name "${STACK_NAME}-manifest-builder" --region $REGION

aws lambda update-function-code \
    --function-name "${STACK_NAME}-control-plane" \
    --s3-bucket "${DEPLOYMENT_BUCKET}" \
    --s3-key "lambda/control-plane.zip" \
    --region $REGION > /dev/null

aws lambda wait function-updated --function-name "${STACK_NAME}-control-plane" --region $REGION

echo -e "${GREEN}✓ Lambda functions updated${NC}"
echo ""

# Step 7: Display outputs
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}DEPLOYMENT SUCCESSFUL!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table

echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Confirm SNS subscription in email (magzine323@gmail.com)"
echo "2. Test the pipeline:"
echo "   aws s3 cp test.ndjson s3://ndjson-input-sqs-${AWS_ACCOUNT_ID}/"
echo "3. Monitor logs:"
echo "   aws logs tail /aws/lambda/${STACK_NAME}-manifest-builder --follow"
echo ""
echo -e "${GREEN}Done!${NC}"
