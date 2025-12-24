#!/bin/bash

# Purge SQS Queue and Restart Fresh
# This clears old S3 events and allows Lambda to reprocess with correct paths

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "${GREEN}Purging SQS Queue and Restarting Pipeline${NC}"
echo ""

# Step 1: Get queue URL
echo -e "${YELLOW}Step 1: Finding SQS queue...${NC}"
QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name "${STACK_NAME}-file-events" \
  --region $REGION \
  --query 'QueueUrl' \
  --output text)

echo "Queue URL: $QUEUE_URL"
echo ""

# Step 2: Purge the queue
echo -e "${YELLOW}Step 2: Purging queue (removing old messages)...${NC}"
aws sqs purge-queue \
  --queue-url "$QUEUE_URL" \
  --region $REGION

echo -e "${GREEN}✓ Queue purged${NC}"
echo ""
echo "Note: Queue will be unavailable for 60 seconds during purge."
echo "Waiting 65 seconds..."
sleep 65

# Step 3: Trigger new S3 events by touching files
echo -e "${YELLOW}Step 3: Triggering new S3 events...${NC}"
INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}"

# List files and copy them to themselves (triggers new S3 event)
FILES=$(aws s3 ls "s3://${INPUT_BUCKET}/" --recursive --region $REGION | grep ".ndjson" | awk '{print $4}' | head -10)

if [ -z "$FILES" ]; then
    echo -e "${RED}No NDJSON files found in bucket${NC}"
    echo "Upload files first with: ./upload-test-data.sh"
    exit 1
fi

echo "Retriggering events for files:"
for FILE in $FILES; do
    echo "  - $FILE"
    # Copy file to itself with metadata update to trigger event
    aws s3 cp "s3://${INPUT_BUCKET}/${FILE}" "s3://${INPUT_BUCKET}/${FILE}" \
      --metadata-directive REPLACE \
      --region $REGION
done

echo ""
echo -e "${GREEN}✓ New S3 events triggered${NC}"
echo ""

# Step 4: Check queue for new messages
echo -e "${YELLOW}Step 4: Waiting for messages (30 seconds)...${NC}"
sleep 30

MESSAGE_COUNT=$(aws sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --region $REGION \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text)

echo "Messages in queue: $MESSAGE_COUNT"
echo ""

if [ "$MESSAGE_COUNT" -gt "0" ]; then
    echo -e "${GREEN}✓ Pipeline restarted successfully${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Wait 1-2 minutes for Lambda to create manifests"
    echo "  2. Check manifests: aws s3 ls s3://ndjson-manifests-${AWS_ACCOUNT_ID}/manifests/ --recursive"
    echo "  3. Run Glue job: ./run-glue-batch.sh"
else
    echo -e "${YELLOW}No messages in queue yet. Lambda might still be processing.${NC}"
    echo "Wait another minute and check for manifests."
fi
