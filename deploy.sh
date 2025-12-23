#!/bin/bash

# NDJSON to Parquet Pipeline Deployment Script
# This script handles all prerequisites and deploys the CloudFormation stack

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="ndjson-parquet-sqs"
TEMPLATE_FILE="configurations/cloudformation-sqs-manifest.yaml"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "${GREEN}Starting deployment for NDJSON to Parquet Pipeline${NC}"
echo "Stack Name: $STACK_NAME"
echo "Region: $REGION"
echo "AWS Account: $AWS_ACCOUNT_ID"
echo ""

# Step 1: Check if stack exists and delete if needed
echo -e "${YELLOW}Step 1: Checking for existing stack...${NC}"
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" != "DOES_NOT_EXIST" ]; then
    echo "Existing stack found with status: $STACK_STATUS"

    if [[ "$STACK_STATUS" == *"ROLLBACK"* ]] || [[ "$STACK_STATUS" == *"FAILED"* ]]; then
        echo -e "${RED}Stack is in failed state. Deleting...${NC}"
        aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
        echo "Waiting for stack deletion to complete..."
        aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION
        echo -e "${GREEN}Stack deleted successfully${NC}"
    else
        echo -e "${YELLOW}Stack exists in stable state. Skipping deletion.${NC}"
        read -p "Do you want to update the existing stack? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Deployment cancelled."
            exit 0
        fi
    fi
else
    echo "No existing stack found."
fi
echo ""

# Step 2: Create temporary S3 bucket for deployment artifacts (if needed)
echo -e "${YELLOW}Step 2: Setting up deployment artifacts bucket...${NC}"
DEPLOYMENT_BUCKET="ndjson-parquet-deployment-${AWS_ACCOUNT_ID}"

# Check if deployment bucket exists
if aws s3 ls "s3://${DEPLOYMENT_BUCKET}" 2>&1 | grep -q 'NoSuchBucket'; then
    echo "Creating deployment bucket: ${DEPLOYMENT_BUCKET}"
    aws s3 mb "s3://${DEPLOYMENT_BUCKET}" --region $REGION

    # Enable versioning for safety
    aws s3api put-bucket-versioning \
        --bucket "${DEPLOYMENT_BUCKET}" \
        --versioning-configuration Status=Enabled \
        --region $REGION
else
    echo "Deployment bucket already exists: ${DEPLOYMENT_BUCKET}"
fi
echo ""

# Step 3: Package and upload Lambda functions
echo -e "${YELLOW}Step 3: Packaging Lambda functions...${NC}"

# Create temp directory for builds
mkdir -p build/lambda
rm -rf build/lambda/*

# Package manifest builder
echo "Packaging manifest builder..."
cd app
zip -q ../build/lambda/manifest-builder.zip lambda_manifest_builder.py
cd ..

# Package control plane
echo "Packaging control plane..."
cd app
zip -q ../build/lambda/control-plane.zip lambda_control_plane.py
cd ..

# Upload to S3
echo "Uploading Lambda packages to S3..."
aws s3 cp build/lambda/manifest-builder.zip "s3://${DEPLOYMENT_BUCKET}/lambda/" --region $REGION
aws s3 cp build/lambda/control-plane.zip "s3://${DEPLOYMENT_BUCKET}/lambda/" --region $REGION

echo -e "${GREEN}Lambda functions packaged and uploaded${NC}"
echo ""

# Step 4: Upload Glue script
echo -e "${YELLOW}Step 4: Uploading Glue streaming job script...${NC}"

# The manifest bucket name (needs to match CloudFormation parameters)
MANIFEST_BUCKET="ndjson-manifests-${AWS_ACCOUNT_ID}"

# Check if manifest bucket exists, create if not (temporary for script upload)
if aws s3 ls "s3://${MANIFEST_BUCKET}" 2>&1 | grep -q 'NoSuchBucket'; then
    echo "Pre-creating manifest bucket for script upload: ${MANIFEST_BUCKET}"
    aws s3 mb "s3://${MANIFEST_BUCKET}" --region $REGION
fi

# Upload Glue script
aws s3 cp app/glue_streaming_job.py "s3://${MANIFEST_BUCKET}/scripts/" --region $REGION
echo -e "${GREEN}Glue script uploaded to s3://${MANIFEST_BUCKET}/scripts/glue_streaming_job.py${NC}"
echo ""

# Step 5: Update CloudFormation template to use uploaded Lambda code
echo -e "${YELLOW}Step 5: Preparing CloudFormation template...${NC}"

# Create a modified version of the template with S3 code locations
cp "$TEMPLATE_FILE" "build/cloudformation-sqs-manifest-modified.yaml"

# Note: We'll keep the inline code for now and update after stack creation
echo "Template prepared"
echo ""

# Step 6: Validate CloudFormation template
echo -e "${YELLOW}Step 6: Validating CloudFormation template...${NC}"
aws cloudformation validate-template \
    --template-body file://$TEMPLATE_FILE \
    --region $REGION > /dev/null

echo -e "${GREEN}Template is valid${NC}"
echo ""

# Step 7: Deploy CloudFormation stack
echo -e "${YELLOW}Step 7: Deploying CloudFormation stack...${NC}"

if [ "$STACK_STATUS" == "DOES_NOT_EXIST" ]; then
    echo "Creating new stack..."
    aws cloudformation create-stack \
        --stack-name $STACK_NAME \
        --template-body file://$TEMPLATE_FILE \
        --capabilities CAPABILITY_NAMED_IAM \
        --tags Key=Environment,Value=Production Key=Team,Value=DataEngineering \
        --region $REGION

    echo "Waiting for stack creation to complete..."
    echo "This may take 5-10 minutes..."

    # Wait for stack creation with better error handling
    if aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION; then
        echo -e "${GREEN}Stack created successfully!${NC}"
    else
        echo -e "${RED}Stack creation failed!${NC}"
        echo "Fetching error details..."
        aws cloudformation describe-stack-events \
            --stack-name $STACK_NAME \
            --region $REGION \
            --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]' \
            --output table
        exit 1
    fi
else
    echo "Updating existing stack..."
    aws cloudformation update-stack \
        --stack-name $STACK_NAME \
        --template-body file://$TEMPLATE_FILE \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION || echo "No updates to perform"
fi
echo ""

# Step 8: Update Lambda function code
echo -e "${YELLOW}Step 8: Updating Lambda function code...${NC}"

# Get Lambda function names from stack outputs
MANIFEST_BUILDER_FUNCTION="${STACK_NAME}-manifest-builder"
CONTROL_PLANE_FUNCTION="${STACK_NAME}-control-plane"

echo "Updating manifest builder function..."
aws lambda update-function-code \
    --function-name $MANIFEST_BUILDER_FUNCTION \
    --s3-bucket "${DEPLOYMENT_BUCKET}" \
    --s3-key "lambda/manifest-builder.zip" \
    --region $REGION > /dev/null

echo "Updating control plane function..."
aws lambda update-function-code \
    --function-name $CONTROL_PLANE_FUNCTION \
    --s3-bucket "${DEPLOYMENT_BUCKET}" \
    --s3-key "lambda/control-plane.zip" \
    --region $REGION > /dev/null

echo -e "${GREEN}Lambda functions updated with actual code${NC}"
echo ""

# Step 9: Display stack outputs
echo -e "${YELLOW}Step 9: Deployment Summary${NC}"
echo ""
aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --region $REGION \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table

echo ""
echo -e "${GREEN}Deployment completed successfully!${NC}"
echo ""
echo "Next steps:"
echo "1. Check your email and confirm the SNS subscription"
echo "2. Upload NDJSON files to the input bucket to test the pipeline"
echo "3. Monitor the CloudWatch dashboard for pipeline metrics"
echo ""
echo "Useful commands:"
echo "  View logs: aws logs tail /aws/lambda/${MANIFEST_BUILDER_FUNCTION} --follow"
echo "  Check queue: aws sqs get-queue-attributes --queue-url <queue-url> --attribute-names All"
echo ""
