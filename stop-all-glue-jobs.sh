#!/bin/bash

# Stop All Running Glue Jobs
# Use this at the end of each testing session to avoid charges

set -e

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
JOB_NAME="${STACK_NAME}-streaming-processor"

echo "Stopping all running Glue jobs..."
echo "Job: $JOB_NAME"
echo ""

RUNNING_JOBS=$(aws glue get-job-runs \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query "JobRuns[?JobRunState=='RUNNING'].Id" \
  --output text)

if [ -z "$RUNNING_JOBS" ]; then
    echo "✓ No running jobs found"
    exit 0
fi

echo "Found running jobs:"
for JOB_ID in $RUNNING_JOBS; do
    echo "  - $JOB_ID"
done
echo ""

echo "Stopping jobs..."
aws glue batch-stop-job-run \
  --job-name "$JOB_NAME" \
  --job-run-ids $RUNNING_JOBS \
  --region $REGION

echo ""
echo "✓ All jobs stopped"
echo ""
echo "Cost saved: Stopped jobs will no longer incur charges"
