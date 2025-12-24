#!/bin/bash

# Fix File Paths - Move files from /input/ to root
# Simple version that works on Windows

set -e

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}"
REGION="us-east-1"

echo "Fixing file paths in bucket: $INPUT_BUCKET"
echo ""

# Move all files from input/ prefix to root
echo "Moving files from /input/ to root of bucket..."
aws s3 mv "s3://${INPUT_BUCKET}/input/" "s3://${INPUT_BUCKET}/" --recursive --region $REGION

echo ""
echo "Done! Files have been moved."
echo ""
echo "Current structure:"
aws s3 ls "s3://${INPUT_BUCKET}/" --recursive --region $REGION
echo ""
echo "Wait 1-2 minutes for Lambda to reprocess the files."
