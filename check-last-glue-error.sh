#!/bin/bash

# Check Last Glue Job Error Details

set -e

# Configuration
STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
JOB_NAME="${STACK_NAME}-streaming-processor"

echo "===== LATEST GLUE JOB RUN DETAILS ====="
echo "Job Name: $JOB_NAME"
echo ""

# Get the latest job run
LATEST_RUN=$(aws glue get-job-runs \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --max-results 1 \
  --query 'JobRuns[0].Id' \
  --output text)

echo "Latest Run ID: $LATEST_RUN"
echo ""

# Get full details of the latest run
echo "===== FULL RUN DETAILS ====="
aws glue get-job-run \
  --job-name "$JOB_NAME" \
  --run-id "$LATEST_RUN" \
  --region $REGION \
  --output json

echo ""
echo "===== CHECKING CLOUDWATCH LOGS ====="
LOG_GROUP="/aws-glue/jobs/error"
echo "Log Group: $LOG_GROUP"
echo "Log Stream: $LATEST_RUN"
echo ""

# Try to get CloudWatch logs
aws logs get-log-events \
  --log-group-name "$LOG_GROUP" \
  --log-stream-name "$LATEST_RUN" \
  --region $REGION \
  --limit 50 \
  --query 'events[*].message' \
  --output text 2>&1 || echo "No error logs found or stream doesn't exist yet"

echo ""
echo "===== CHECKING OUTPUT LOGS ====="
LOG_GROUP_OUTPUT="/aws-glue/jobs/output"
aws logs get-log-events \
  --log-group-name "$LOG_GROUP_OUTPUT" \
  --log-stream-name "$LATEST_RUN" \
  --region $REGION \
  --limit 50 \
  --query 'events[*].message' \
  --output text 2>&1 || echo "No output logs found or stream doesn't exist yet"
