#!/bin/bash

# Update Lambda Functions with Latest Code

set -e

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
DEPLOYMENT_BUCKET="ndjson-parquet-deployment-${AWS_ACCOUNT_ID}"

echo "Updating Lambda functions..."
echo ""

# Update manifest builder
echo "Updating manifest builder..."
aws lambda update-function-code \
  --function-name "${STACK_NAME}-manifest-builder" \
  --s3-bucket "${DEPLOYMENT_BUCKET}" \
  --s3-key "lambda/manifest-builder.zip" \
  --region $REGION > /dev/null

echo "Waiting for update to complete..."
aws lambda wait function-updated \
  --function-name "${STACK_NAME}-manifest-builder" \
  --region $REGION

echo "✓ Manifest builder updated"
echo ""

# Update control plane
echo "Updating control plane..."
aws lambda update-function-code \
  --function-name "${STACK_NAME}-control-plane" \
  --s3-bucket "${DEPLOYMENT_BUCKET}" \
  --s3-key "lambda/control-plane.zip" \
  --region $REGION > /dev/null

echo "Waiting for update to complete..."
aws lambda wait function-updated \
  --function-name "${STACK_NAME}-control-plane" \
  --region $REGION

echo "✓ Control plane updated"
echo ""

echo "All Lambda functions updated successfully!"
