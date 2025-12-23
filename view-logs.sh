#!/bin/bash

# View Lambda function logs
# Usage: ./view-logs.sh [function-name]

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"

# Determine which function to tail
if [ -z "$1" ]; then
    FUNCTION="manifest-builder"
else
    FUNCTION="$1"
fi

LOG_GROUP="/aws/lambda/${STACK_NAME}-${FUNCTION}"

echo "Tailing logs for: $LOG_GROUP"
echo "Press Ctrl+C to stop"
echo ""

# Use MSYS_NO_PATHCONV to prevent Git Bash path conversion
MSYS_NO_PATHCONV=1 aws logs tail "$LOG_GROUP" --follow --region $REGION
