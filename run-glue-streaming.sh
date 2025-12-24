#!/bin/bash

# Start Glue Job in Streaming Mode
# This starts the job WITHOUT a manifest path, so it watches for new manifests continuously

set -e

# Configuration
STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
JOB_NAME="${STACK_NAME}-streaming-processor"

echo "Starting Glue job in STREAMING mode..."
echo "Job Name: $JOB_NAME"
echo "Region: $REGION"
echo ""
echo "The job will continuously watch for new manifest files and process them."
echo "It will keep running until you manually stop it."
echo ""

# Start the job WITHOUT --MANIFEST_PATH (streaming mode)
JOB_RUN_ID=$(aws glue start-job-run \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query 'JobRunId' \
  --output text)

echo "✓ Glue job started successfully!"
echo "Job Run ID: $JOB_RUN_ID"
echo ""
echo "Monitor the job:"
echo "  aws glue get-job-run --job-name $JOB_NAME --run-id $JOB_RUN_ID --region $REGION"
echo ""
echo "View logs:"
echo "  aws logs tail /aws-glue/jobs/output --follow --log-stream-names $JOB_RUN_ID"
echo ""
echo "Stop the job:"
echo "  aws glue batch-stop-job-run --job-name $JOB_NAME --job-run-ids $JOB_RUN_ID --region $REGION"
