#!/bin/bash

# Check Recent Glue Job Error
# Gets detailed error from the most recent failed Glue job run

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
JOB_NAME="${STACK_NAME}-streaming-processor"

echo -e "${GREEN}Checking Recent Glue Job Errors${NC}"
echo ""

# Get the most recent job run
echo -e "${YELLOW}Recent job runs:${NC}"
aws glue get-job-runs \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --max-results 5 \
  --query 'JobRuns[*].{Time:StartedOn,State:JobRunState,ID:Id}' \
  --output table

echo ""

# Get the most recent failed job
FAILED_JOB=$(aws glue get-job-runs \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --max-results 10 \
  --output json | python -c "
import sys, json
data = json.load(sys.stdin)
for job in data['JobRuns']:
    if job['JobRunState'] == 'FAILED':
        print(job['Id'])
        break
")

if [ -z "$FAILED_JOB" ]; then
    echo "No failed jobs found"
    exit 0
fi

echo -e "${YELLOW}Most recent failed job: $FAILED_JOB${NC}"
echo ""

# Get full error details
echo -e "${RED}Error details:${NC}"
aws glue get-job-run \
  --job-name "$JOB_NAME" \
  --run-id "$FAILED_JOB" \
  --region $REGION \
  --query 'JobRun.ErrorMessage' \
  --output text

echo ""
echo ""
echo -e "${YELLOW}Job arguments:${NC}"
aws glue get-job-run \
  --job-name "$JOB_NAME" \
  --run-id "$FAILED_JOB" \
  --region $REGION \
  --query 'JobRun.Arguments' \
  --output json

echo ""
echo -e "${GREEN}Check complete${NC}"
