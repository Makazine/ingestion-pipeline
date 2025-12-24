#!/bin/bash

# Fix Glue Job Environment Variables
# Adds the required arguments back to the Glue job

set -e

# Configuration
STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
JOB_NAME="${STACK_NAME}-streaming-processor"
MANIFEST_BUCKET="ndjson-manifests-${AWS_ACCOUNT_ID}"
OUTPUT_BUCKET="ndjson-parquet-output-${AWS_ACCOUNT_ID}"

echo "Fixing Glue job environment variables..."
echo "Job Name: $JOB_NAME"
echo "Manifest Bucket: $MANIFEST_BUCKET"
echo "Output Bucket: $OUTPUT_BUCKET"
echo ""

# Get current job configuration to preserve Command and Role
echo "Retrieving current job configuration..."
DEPLOYMENT_BUCKET="ndjson-parquet-deployment-${AWS_ACCOUNT_ID}"

JOB_CONFIG=$(aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --output json)

GLUE_ROLE=$(echo "$JOB_CONFIG" | python -c "import sys, json; print(json.load(sys.stdin)['Job']['Role'])")
SCRIPT_LOCATION=$(echo "$JOB_CONFIG" | python -c "import sys, json; print(json.load(sys.stdin)['Job']['Command']['ScriptLocation'])")

echo "Role: $GLUE_ROLE"
echo "Script: $SCRIPT_LOCATION"
echo ""

# Update the Glue job with required arguments while preserving Command and Role
echo "Updating Glue job arguments..."
aws glue update-job \
  --job-name "$JOB_NAME" \
  --job-update '{
    "Role": "'"${GLUE_ROLE}"'",
    "Command": {
      "Name": "glueetl",
      "ScriptLocation": "'"${SCRIPT_LOCATION}"'",
      "PythonVersion": "3"
    },
    "DefaultArguments": {
      "--job-language": "python",
      "--job-bookmark-option": "job-bookmark-disable",
      "--enable-metrics": "true",
      "--enable-spark-ui": "true",
      "--spark-event-logs-path": "s3://'"${MANIFEST_BUCKET}"'/spark-logs/",
      "--enable-continuous-cloudwatch-log": "true",
      "--enable-continuous-log-filter": "true",
      "--MANIFEST_BUCKET": "'"${MANIFEST_BUCKET}"'",
      "--OUTPUT_BUCKET": "'"${OUTPUT_BUCKET}"'",
      "--COMPRESSION_TYPE": "snappy"
    }
  }' \
  --region $REGION

echo ""
echo "✓ Environment variables updated successfully!"
echo ""

# Display current configuration
echo "Current DefaultArguments:"
aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query 'Job.DefaultArguments' \
  --output json

echo ""
echo "Done! You can now run the Glue job."
