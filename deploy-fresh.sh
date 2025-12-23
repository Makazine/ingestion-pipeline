#!/bin/bash

# Fresh NDJSON to Parquet Pipeline Deployment Script
# This script deploys from scratch with detailed logging

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="ndjson-parquet-sqs"
TEMPLATE_FILE="configurations/cloudformation-sqs-manifest.yaml"
REGION="us-east-1"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}NDJSON to Parquet Pipeline Deployment${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Step 0: Verify AWS credentials
echo -e "${BLUE}Step 0: Verifying AWS credentials...${NC}"
if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
    echo -e "${RED}ERROR: AWS credentials not configured or expired!${NC}"
    echo "Please run: aws configure"
    echo "Or set environment variables:"
    echo "  export AWS_ACCESS_KEY_ID=..."
    echo "  export AWS_SECRET_ACCESS_KEY=..."
    echo "  export AWS_SESSION_TOKEN=...  # if using temporary credentials"
    exit 1
fi

echo -e "${GREEN}✓ AWS Account: $AWS_ACCOUNT_ID${NC}"
echo -e "${GREEN}✓ Region: $REGION${NC}"
echo ""

# Step 1: Check for existing resources
echo -e "${BLUE}Step 1: Checking for existing resources...${NC}"

# Check for existing stacks
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" != "DOES_NOT_EXIST" ]; then
    echo -e "${YELLOW}⚠ Stack exists with status: $STACK_STATUS${NC}"

    if [[ "$STACK_STATUS" == *"ROLLBACK"* ]] || [[ "$STACK_STATUS" == *"FAILED"* ]]; then
        echo -e "${RED}Stack is in failed state. Deleting...${NC}"
        aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
        echo "Waiting for stack deletion..."
        aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION
        echo -e "${GREEN}✓ Stack deleted${NC}"
    else
        echo -e "${RED}ERROR: Stack already exists in stable state${NC}"
        echo "Please delete it manually or use a different stack name"
        exit 1
    fi
else
    echo -e "${GREEN}✓ No existing stack found${NC}"
fi

# Check for existing S3 buckets
echo "Checking for existing S3 buckets..."
EXISTING_BUCKETS=$(aws s3 ls | grep -E "(ndjson-input-sqs|ndjson-manifests|parquet-output-sqs|ndjson-quarantine|ndjson-parquet-sqs-logs)" || true)

if [ ! -z "$EXISTING_BUCKETS" ]; then
    echo -e "${YELLOW}⚠ Found existing buckets:${NC}"
    echo "$EXISTING_BUCKETS"
    echo ""
    read -p "Delete these buckets? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Deleting buckets..."
        aws s3 rb "s3://ndjson-input-sqs-${AWS_ACCOUNT_ID}" --force 2>/dev/null || true
        aws s3 rb "s3://ndjson-manifests-${AWS_ACCOUNT_ID}" --force 2>/dev/null || true
        aws s3 rb "s3://parquet-output-sqs-${AWS_ACCOUNT_ID}" --force 2>/dev/null || true
        aws s3 rb "s3://ndjson-quarantine-${AWS_ACCOUNT_ID}" --force 2>/dev/null || true
        aws s3 rb "s3://ndjson-parquet-sqs-logs-${AWS_ACCOUNT_ID}" --force 2>/dev/null || true
        echo -e "${GREEN}✓ Buckets deleted${NC}"
    else
        echo -e "${RED}ERROR: Cannot proceed with existing buckets${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}✓ No existing buckets found${NC}"
fi
echo ""

# Step 2: Create deployment bucket
echo -e "${BLUE}Step 2: Setting up deployment bucket...${NC}"
DEPLOYMENT_BUCKET="ndjson-parquet-deployment-${AWS_ACCOUNT_ID}"

if aws s3 ls "s3://${DEPLOYMENT_BUCKET}" 2>&1 | grep -q 'NoSuchBucket'; then
    echo "Creating deployment bucket: ${DEPLOYMENT_BUCKET}"
    aws s3 mb "s3://${DEPLOYMENT_BUCKET}" --region $REGION
    aws s3api put-bucket-versioning \
        --bucket "${DEPLOYMENT_BUCKET}" \
        --versioning-configuration Status=Enabled \
        --region $REGION
    echo -e "${GREEN}✓ Deployment bucket created${NC}"
else
    echo -e "${GREEN}✓ Deployment bucket already exists${NC}"
fi
echo ""

# Step 3: Pre-create manifest bucket and upload Glue script
echo -e "${BLUE}Step 3: Preparing Glue script...${NC}"
MANIFEST_BUCKET="ndjson-manifests-${AWS_ACCOUNT_ID}"

echo "Creating manifest bucket: ${MANIFEST_BUCKET}"
aws s3 mb "s3://${MANIFEST_BUCKET}" --region $REGION 2>/dev/null || echo "Bucket already exists"

echo "Uploading Glue script..."
if [ ! -f "app/glue_streaming_job.py" ]; then
    echo -e "${RED}ERROR: app/glue_streaming_job.py not found!${NC}"
    exit 1
fi

aws s3 cp app/glue_streaming_job.py "s3://${MANIFEST_BUCKET}/scripts/glue_streaming_job.py" --region $REGION
echo -e "${GREEN}✓ Glue script uploaded to s3://${MANIFEST_BUCKET}/scripts/glue_streaming_job.py${NC}"
echo ""

# Step 4: Package Lambda functions
echo -e "${BLUE}Step 4: Packaging Lambda functions...${NC}"

mkdir -p build/lambda
rm -rf build/lambda/*

echo "Packaging manifest builder..."
if [ ! -f "app/lambda_manifest_builder.py" ]; then
    echo -e "${RED}ERROR: app/lambda_manifest_builder.py not found!${NC}"
    exit 1
fi
(cd app && zip -q ../build/lambda/manifest-builder.zip lambda_manifest_builder.py)

echo "Packaging control plane..."
if [ ! -f "app/lambda_control_plane.py" ]; then
    echo -e "${RED}ERROR: app/lambda_control_plane.py not found!${NC}"
    exit 1
fi
(cd app && zip -q ../build/lambda/control-plane.zip lambda_control_plane.py)

echo "Uploading Lambda packages..."
aws s3 cp build/lambda/manifest-builder.zip "s3://${DEPLOYMENT_BUCKET}/lambda/" --region $REGION
aws s3 cp build/lambda/control-plane.zip "s3://${DEPLOYMENT_BUCKET}/lambda/" --region $REGION

echo -e "${GREEN}✓ Lambda functions packaged and uploaded${NC}"
echo ""

# Step 5: Validate template
echo -e "${BLUE}Step 5: Validating CloudFormation template...${NC}"
if [ ! -f "$TEMPLATE_FILE" ]; then
    echo -e "${RED}ERROR: Template file not found: $TEMPLATE_FILE${NC}"
    exit 1
fi

if aws cloudformation validate-template --template-body file://$TEMPLATE_FILE --region $REGION > /dev/null; then
    echo -e "${GREEN}✓ Template is valid${NC}"
else
    echo -e "${RED}ERROR: Template validation failed${NC}"
    exit 1
fi
echo ""

# Step 6: Deploy CloudFormation stack
echo -e "${BLUE}Step 6: Deploying CloudFormation stack...${NC}"
echo "This will take 5-10 minutes..."
echo ""

aws cloudformation create-stack \
    --stack-name $STACK_NAME \
    --template-body file://$TEMPLATE_FILE \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags Key=Environment,Value=Production Key=Team,Value=DataEngineering \
    --region $REGION

echo "Stack creation initiated. Monitoring progress..."
echo ""

# Monitor stack creation with live updates
echo "Waiting for stack creation to complete..."
if aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION 2>&1; then
    echo -e "${GREEN}✓ Stack created successfully!${NC}"
else
    echo -e "${RED}✗ Stack creation FAILED!${NC}"
    echo ""
    echo "Failed resources:"
    aws cloudformation describe-stack-events \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]' \
        --output table
    exit 1
fi
echo ""

# Step 7: Update Lambda function code
echo -e "${BLUE}Step 7: Updating Lambda functions with actual code...${NC}"

MANIFEST_BUILDER_FUNCTION="${STACK_NAME}-manifest-builder"
CONTROL_PLANE_FUNCTION="${STACK_NAME}-control-plane"

echo "Updating manifest builder..."
aws lambda update-function-code \
    --function-name $MANIFEST_BUILDER_FUNCTION \
    --s3-bucket "${DEPLOYMENT_BUCKET}" \
    --s3-key "lambda/manifest-builder.zip" \
    --region $REGION > /dev/null

echo "Waiting for function update..."
aws lambda wait function-updated --function-name $MANIFEST_BUILDER_FUNCTION --region $REGION

echo "Updating control plane..."
aws lambda update-function-code \
    --function-name $CONTROL_PLANE_FUNCTION \
    --s3-bucket "${DEPLOYMENT_BUCKET}" \
    --s3-key "lambda/control-plane.zip" \
    --region $REGION > /dev/null

echo "Waiting for function update..."
aws lambda wait function-updated --function-name $CONTROL_PLANE_FUNCTION --region $REGION

echo -e "${GREEN}✓ Lambda functions updated${NC}"
echo ""

# Step 8: Display outputs
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}DEPLOYMENT SUCCESSFUL!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}Stack Outputs:${NC}"
aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table

echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Check your email (magzine323@gmail.com) and confirm the SNS subscription"
echo "2. Upload NDJSON files to test:"
echo "   aws s3 cp test-file.ndjson s3://ndjson-input-sqs-${AWS_ACCOUNT_ID}/"
echo "3. Monitor the pipeline:"
echo "   aws logs tail /aws/lambda/${MANIFEST_BUILDER_FUNCTION} --follow"
echo ""
echo -e "${YELLOW}Useful Commands:${NC}"
echo "  View all resources:"
echo "    aws cloudformation list-stack-resources --stack-name $STACK_NAME"
echo ""
echo "  Check SQS queue:"
echo "    aws sqs get-queue-attributes --queue-url <url> --attribute-names All"
echo ""
echo "  View Glue jobs:"
echo "    aws glue list-jobs"
echo ""
echo -e "${GREEN}Deployment completed at $(date)${NC}"
