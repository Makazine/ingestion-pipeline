#!/bin/bash

# Check Glue Job Configuration
# Displays all current configuration for debugging

set -e

# Configuration
STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
JOB_NAME="${STACK_NAME}-streaming-processor"

echo "===== GLUE JOB CONFIGURATION ====="
echo "Job Name: $JOB_NAME"
echo "Region: $REGION"
echo ""

# Get full job configuration
echo "===== FULL JOB DETAILS ====="
aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --output json

echo ""
echo "===== CHECKING SCRIPT LOCATION ====="
SCRIPT_LOCATION=$(aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query 'Job.Command.ScriptLocation' \
  --output text)

echo "Script Location: $SCRIPT_LOCATION"
echo ""

# Try to access the script
echo "Checking if script exists in S3..."
BUCKET=$(echo "$SCRIPT_LOCATION" | sed 's|s3://||' | cut -d'/' -f1)
KEY=$(echo "$SCRIPT_LOCATION" | sed 's|s3://||' | cut -d'/' -f2-)

echo "Bucket: $BUCKET"
echo "Key: $KEY"
echo ""

aws s3 ls "s3://${BUCKET}/${KEY}" 2>&1 && echo "✓ Script exists" || echo "✗ Script NOT found"

echo ""
echo "===== CHECKING BUCKETS ====="
MANIFEST_BUCKET=$(aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query 'Job.DefaultArguments."--MANIFEST_BUCKET"' \
  --output text)

OUTPUT_BUCKET=$(aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query 'Job.DefaultArguments."--OUTPUT_BUCKET"' \
  --output text)

echo "Manifest Bucket: $MANIFEST_BUCKET"
echo "Output Bucket: $OUTPUT_BUCKET"
echo ""

echo "Checking if buckets exist..."
aws s3 ls "s3://${MANIFEST_BUCKET}/" 2>&1 > /dev/null && echo "✓ Manifest bucket exists" || echo "✗ Manifest bucket NOT found"
aws s3 ls "s3://${OUTPUT_BUCKET}/" 2>&1 > /dev/null && echo "✓ Output bucket exists" || echo "✗ Output bucket NOT found"

echo ""
echo "===== RECENT JOB RUNS ====="
aws glue get-job-runs \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --max-results 3 \
  --query 'JobRuns[*].[Id,JobRunState,ErrorMessage,StartedOn]' \
  --output table
