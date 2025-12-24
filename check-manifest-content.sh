#!/bin/bash

# Check Manifest Content
# Downloads and displays a sample manifest file

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
MANIFEST_BUCKET="ndjson-manifests-${AWS_ACCOUNT_ID}"
REGION="us-east-1"

echo -e "${GREEN}Checking Manifest Files${NC}"
echo "Bucket: s3://${MANIFEST_BUCKET}"
echo ""

# Get list of recent manifests
echo -e "${YELLOW}Finding recent manifests...${NC}"
MANIFEST_LIST=$(aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/" --recursive --region $REGION | grep "\.json$" | tail -10)

if [ -z "$MANIFEST_LIST" ]; then
    echo "No manifests found!"
    exit 1
fi

echo "Found manifests:"
echo "$MANIFEST_LIST"
echo ""

# Get the most recent one
LATEST_MANIFEST=$(echo "$MANIFEST_LIST" | tail -1 | awk '{print $4}')
echo -e "${YELLOW}Most recent manifest: $LATEST_MANIFEST${NC}"
echo ""

# Download and display it
echo -e "${YELLOW}Manifest content:${NC}"
echo "----------------------------------------"
aws s3 cp "s3://${MANIFEST_BUCKET}/${LATEST_MANIFEST}" - --region $REGION | python -m json.tool
echo "----------------------------------------"
echo ""

# Count files in manifest
FILE_COUNT=$(aws s3 cp "s3://${MANIFEST_BUCKET}/${LATEST_MANIFEST}" - --region $REGION | python -c "
import sys, json
data = json.load(sys.stdin)
count = 0
for loc in data.get('fileLocations', []):
    count += len(loc.get('URIPrefixes', []))
print(count)
")

echo -e "${GREEN}Files in this manifest: $FILE_COUNT${NC}"
echo ""

# Check total manifest count by date
echo -e "${YELLOW}Manifest count by date:${NC}"
aws s3 ls "s3://${MANIFEST_BUCKET}/manifests/" --recursive --region $REGION | awk '{print $4}' | cut -d'/' -f2 | sort | uniq -c

echo ""
echo -e "${GREEN}Check complete${NC}"
