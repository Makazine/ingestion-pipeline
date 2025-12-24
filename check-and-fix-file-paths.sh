#!/bin/bash

# Check and Fix File Paths in Input Bucket
# Moves files from /input/ prefix to root if needed

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
INPUT_BUCKET="ndjson-input-sqs-${AWS_ACCOUNT_ID}"
REGION="us-east-1"

echo -e "${GREEN}Checking File Locations in Input Bucket${NC}"
echo "Bucket: s3://${INPUT_BUCKET}"
echo ""

# Check for files in /input/ prefix
echo -e "${YELLOW}Checking for files in /input/ prefix...${NC}"

# Use aws s3 sync with exclude/include to move files
aws s3 ls "s3://${INPUT_BUCKET}/input/" --recursive --region $REGION > /tmp/input_files.txt 2>&1 || true

if grep -q "ndjson" /tmp/input_files.txt 2>/dev/null; then
    echo -e "${RED}Found files in /input/ prefix (WRONG location)${NC}"
    cat /tmp/input_files.txt
    echo ""

    echo -e "${YELLOW}Moving files to correct location...${NC}"

    # Use aws s3 mv to move the entire input/ directory contents
    aws s3 mv "s3://${INPUT_BUCKET}/input/" "s3://${INPUT_BUCKET}/" --recursive --region $REGION

    echo ""
    echo -e "${GREEN}✓ Files moved successfully${NC}"
else
    echo "✓ No files found in /input/ prefix"
fi

rm -f /tmp/input_files.txt

echo ""
echo -e "${YELLOW}Current file structure:${NC}"
aws s3 ls "s3://${INPUT_BUCKET}/" --recursive --region $REGION | head -20

echo ""
echo -e "${GREEN}File structure check complete${NC}"
echo ""
echo "Correct structure should be:"
echo "  s3://${INPUT_BUCKET}/YYYY-MM-DD/filename.ndjson"
echo ""
echo "NOT:"
echo "  s3://${INPUT_BUCKET}/input/YYYY-MM-DD/filename.ndjson"
echo ""
