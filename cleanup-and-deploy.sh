#!/bin/bash

# Cleanup and Deploy Script for NDJSON to Parquet Pipeline
# This script removes all existing resources and does a clean deployment

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Cleanup and Fresh Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Verify AWS credentials
echo -e "${BLUE}Verifying AWS credentials...${NC}"
if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
    echo -e "${RED}ERROR: AWS credentials not configured!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ AWS Account: $AWS_ACCOUNT_ID${NC}"
echo ""

# Step 1: Delete existing stack if it exists
echo -e "${BLUE}Step 1: Checking for existing CloudFormation stack...${NC}"
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "DOES_NOT_EXIST")

if [ "$STACK_STATUS" != "DOES_NOT_EXIST" ]; then
    echo -e "${YELLOW}Stack exists with status: $STACK_STATUS${NC}"
    echo "Deleting stack..."
    aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
    echo "Waiting for deletion..."
    aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION 2>/dev/null || true
    echo -e "${GREEN}✓ Stack deleted${NC}"
else
    echo -e "${GREEN}✓ No stack found${NC}"
fi
echo ""

# Step 2: Delete existing S3 buckets
echo -e "${BLUE}Step 2: Cleaning up S3 buckets...${NC}"

BUCKETS=(
    "ndjson-input-sqs-${AWS_ACCOUNT_ID}"
    "ndjson-manifests-${AWS_ACCOUNT_ID}"
    "parquet-output-sqs-${AWS_ACCOUNT_ID}"
    "ndjson-quarantine-${AWS_ACCOUNT_ID}"
    "ndjson-parquet-sqs-logs-${AWS_ACCOUNT_ID}"
)

for BUCKET in "${BUCKETS[@]}"; do
    if aws s3 ls "s3://${BUCKET}" 2>/dev/null; then
        echo "Deleting bucket: ${BUCKET}"
        aws s3 rb "s3://${BUCKET}" --force --region $REGION 2>/dev/null || {
            echo -e "${YELLOW}⚠ Could not delete ${BUCKET}, trying to empty first...${NC}"
            aws s3 rm "s3://${BUCKET}" --recursive --region $REGION 2>/dev/null || true
            aws s3 rb "s3://${BUCKET}" --force --region $REGION 2>/dev/null || true
        }
    fi
done

echo -e "${GREEN}✓ S3 buckets cleaned${NC}"
echo ""

# Step 3: Delete DynamoDB tables
echo -e "${BLUE}Step 3: Cleaning up DynamoDB tables...${NC}"

TABLES=(
    "ndjson-parquet-sqs-file-tracking"
    "ndjson-parquet-sqs-metrics"
)

for TABLE in "${TABLES[@]}"; do
    if aws dynamodb describe-table --table-name "$TABLE" --region $REGION 2>/dev/null; then
        echo "Deleting table: ${TABLE}"
        aws dynamodb delete-table --table-name "$TABLE" --region $REGION
        # Wait for deletion
        echo "  Waiting for table deletion..."
        aws dynamodb wait table-not-exists --table-name "$TABLE" --region $REGION 2>/dev/null || true
    fi
done

echo -e "${GREEN}✓ DynamoDB tables cleaned${NC}"
echo ""

# Step 4: Delete SQS queues
echo -e "${BLUE}Step 4: Cleaning up SQS queues...${NC}"

QUEUES=(
    "ndjson-parquet-sqs-file-events"
    "ndjson-parquet-sqs-file-events-dlq"
)

for QUEUE in "${QUEUES[@]}"; do
    QUEUE_URL="https://sqs.${REGION}.amazonaws.com/${AWS_ACCOUNT_ID}/${QUEUE}"
    if aws sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names All --region $REGION 2>/dev/null; then
        echo "Deleting queue: ${QUEUE}"
        aws sqs delete-queue --queue-url "$QUEUE_URL" --region $REGION
    fi
done

echo -e "${GREEN}✓ SQS queues cleaned${NC}"
echo ""

# Step 5: Delete SNS topics
echo -e "${BLUE}Step 5: Cleaning up SNS topics...${NC}"

TOPIC_ARN="arn:aws:sns:${REGION}:${AWS_ACCOUNT_ID}:ndjson-parquet-sqs-alerts"
if aws sns get-topic-attributes --topic-arn "$TOPIC_ARN" --region $REGION 2>/dev/null; then
    echo "Deleting SNS topic..."
    aws sns delete-topic --topic-arn "$TOPIC_ARN" --region $REGION
fi

echo -e "${GREEN}✓ SNS topics cleaned${NC}"
echo ""

# Step 6: Delete Lambda functions (if any exist outside stack)
echo -e "${BLUE}Step 6: Cleaning up Lambda functions...${NC}"

FUNCTIONS=(
    "ndjson-parquet-sqs-manifest-builder"
    "ndjson-parquet-sqs-control-plane"
)

for FUNC in "${FUNCTIONS[@]}"; do
    if aws lambda get-function --function-name "$FUNC" --region $REGION 2>/dev/null; then
        echo "Deleting function: ${FUNC}"
        aws lambda delete-function --function-name "$FUNC" --region $REGION
    fi
done

echo -e "${GREEN}✓ Lambda functions cleaned${NC}"
echo ""

# Step 7: Delete IAM roles (if any exist outside stack)
echo -e "${BLUE}Step 7: Cleaning up IAM roles...${NC}"

ROLES=(
    "ndjson-parquet-sqs-manifest-builder-role"
    "ndjson-parquet-sqs-control-plane-role"
    "ndjson-parquet-sqs-glue-job-role"
)

for ROLE in "${ROLES[@]}"; do
    if aws iam get-role --role-name "$ROLE" 2>/dev/null; then
        echo "Detaching policies from role: ${ROLE}"
        # Detach all managed policies
        for POLICY_ARN in $(aws iam list-attached-role-policies --role-name "$ROLE" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
            aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$POLICY_ARN" 2>/dev/null || true
        done

        # Delete inline policies
        for POLICY_NAME in $(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames[*]' --output text 2>/dev/null); do
            aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POLICY_NAME" 2>/dev/null || true
        done

        echo "Deleting role: ${ROLE}"
        aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
    fi
done

echo -e "${GREEN}✓ IAM roles cleaned${NC}"
echo ""

# Step 8: Wait a bit for AWS to propagate deletions
echo -e "${BLUE}Step 8: Waiting for AWS to propagate deletions...${NC}"
sleep 10
echo -e "${GREEN}✓ Ready for deployment${NC}"
echo ""

# Step 9: Create deployment bucket
echo -e "${BLUE}Step 9: Setting up deployment bucket...${NC}"
DEPLOYMENT_BUCKET="ndjson-parquet-deployment-${AWS_ACCOUNT_ID}"

if aws s3 ls "s3://${DEPLOYMENT_BUCKET}" 2>&1 | grep -q 'NoSuchBucket'; then
    echo "Creating deployment bucket..."
    aws s3 mb "s3://${DEPLOYMENT_BUCKET}" --region $REGION
    aws s3api put-bucket-versioning \
        --bucket "${DEPLOYMENT_BUCKET}" \
        --versioning-configuration Status=Enabled \
        --region $REGION
else
    echo "Deployment bucket already exists"
fi
echo -e "${GREEN}✓ Deployment bucket ready${NC}"
echo ""

# Step 10: Package and upload Lambda functions
echo -e "${BLUE}Step 10: Packaging Lambda functions...${NC}"

mkdir -p build/lambda
rm -rf build/lambda/*

echo "Packaging manifest builder..."
(cd app && zip -q ../build/lambda/manifest-builder.zip lambda_manifest_builder.py)

echo "Packaging control plane..."
(cd app && zip -q ../build/lambda/control-plane.zip lambda_control_plane.py)

echo "Uploading to S3..."
aws s3 cp build/lambda/manifest-builder.zip "s3://${DEPLOYMENT_BUCKET}/lambda/" --region $REGION
aws s3 cp build/lambda/control-plane.zip "s3://${DEPLOYMENT_BUCKET}/lambda/" --region $REGION

echo -e "${GREEN}✓ Lambda packages ready${NC}"
echo ""

# Step 11: Upload Glue script to deployment bucket (NOT manifest bucket)
echo -e "${BLUE}Step 11: Uploading Glue script...${NC}"

echo "Uploading Glue script to deployment bucket..."
aws s3 cp app/glue_streaming_job.py "s3://${DEPLOYMENT_BUCKET}/scripts/" --region $REGION

echo -e "${GREEN}✓ Glue script uploaded to s3://${DEPLOYMENT_BUCKET}/scripts/${NC}"
echo ""

# Step 12: Update CloudFormation template to use deployment bucket for Glue script
echo -e "${BLUE}Step 12: Preparing CloudFormation template...${NC}"

# Create a modified template that uses the deployment bucket for initial Glue script
cp configurations/cloudformation-sqs-manifest.yaml build/cloudformation-modified.yaml

# Update the Glue script location to use deployment bucket initially
sed -i "s|s3://\${ManifestBucket}/scripts/glue_streaming_job.py|s3://${DEPLOYMENT_BUCKET}/scripts/glue_streaming_job.py|g" build/cloudformation-modified.yaml

echo -e "${GREEN}✓ Template prepared${NC}"
echo ""

# Step 13: Validate template
echo -e "${BLUE}Step 13: Validating CloudFormation template...${NC}"
aws cloudformation validate-template \
    --template-body file://build/cloudformation-modified.yaml \
    --region $REGION > /dev/null

echo -e "${GREEN}✓ Template is valid${NC}"
echo ""

# Step 14: Deploy CloudFormation stack
echo -e "${BLUE}Step 14: Deploying CloudFormation stack...${NC}"
echo "This will take 5-10 minutes..."
echo ""

aws cloudformation create-stack \
    --stack-name $STACK_NAME \
    --template-body file://build/cloudformation-modified.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags Key=Environment,Value=Production Key=Team,Value=DataEngineering \
    --region $REGION

echo "Monitoring stack creation..."
if aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION 2>&1; then
    echo -e "${GREEN}✓ Stack created successfully!${NC}"
else
    echo -e "${RED}✗ Stack creation FAILED!${NC}"
    echo ""
    echo "Error details:"
    aws cloudformation describe-stack-events \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]' \
        --output table
    exit 1
fi
echo ""

# Step 15: Copy Glue script to manifest bucket
echo -e "${BLUE}Step 15: Copying Glue script to manifest bucket...${NC}"
MANIFEST_BUCKET="ndjson-manifests-${AWS_ACCOUNT_ID}"

aws s3 cp "s3://${DEPLOYMENT_BUCKET}/scripts/glue_streaming_job.py" \
    "s3://${MANIFEST_BUCKET}/scripts/glue_streaming_job.py" \
    --region $REGION

echo -e "${GREEN}✓ Glue script copied to manifest bucket${NC}"
echo ""

# Step 16: Update Lambda functions with actual code
echo -e "${BLUE}Step 16: Updating Lambda functions...${NC}"

MANIFEST_BUILDER_FUNCTION="${STACK_NAME}-manifest-builder"
CONTROL_PLANE_FUNCTION="${STACK_NAME}-control-plane"

echo "Updating manifest builder..."
aws lambda update-function-code \
    --function-name $MANIFEST_BUILDER_FUNCTION \
    --s3-bucket "${DEPLOYMENT_BUCKET}" \
    --s3-key "lambda/manifest-builder.zip" \
    --region $REGION > /dev/null

aws lambda wait function-updated --function-name $MANIFEST_BUILDER_FUNCTION --region $REGION

echo "Updating control plane..."
aws lambda update-function-code \
    --function-name $CONTROL_PLANE_FUNCTION \
    --s3-bucket "${DEPLOYMENT_BUCKET}" \
    --s3-key "lambda/control-plane.zip" \
    --region $REGION > /dev/null

aws lambda wait function-updated --function-name $CONTROL_PLANE_FUNCTION --region $REGION

echo -e "${GREEN}✓ Lambda functions updated${NC}"
echo ""

# Step 17: Display outputs
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
echo "1. Check email (magzine323@gmail.com) and confirm SNS subscription"
echo "2. Upload test NDJSON files:"
echo "   aws s3 cp test.ndjson s3://ndjson-input-sqs-${AWS_ACCOUNT_ID}/"
echo "3. Monitor logs:"
echo "   aws logs tail /aws/lambda/${MANIFEST_BUILDER_FUNCTION} --follow"
echo ""
echo -e "${GREEN}Deployment completed at $(date)${NC}"
