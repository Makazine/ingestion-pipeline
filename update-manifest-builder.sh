#!/bin/bash

# update-manifest-builder.sh
# Quick update script for Manifest Builder Lambda only

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

FUNCTION_NAME="ndjson-parquet-sqs-ManifestBuilderFunction"
LAMBDA_FILE="app/lambda_manifest_builder.py"
BUILD_DIR="build/lambda"
ZIP_FILE="$BUILD_DIR/manifest-builder.zip"

echo -e "${BLUE}[INFO]${NC} Updating Manifest Builder Lambda..."

# Step 1: Create build directory
mkdir -p "$BUILD_DIR"

# Step 2: Package Lambda
echo -e "${BLUE}[INFO]${NC} Packaging Lambda function..."
cd app
zip -q "../$ZIP_FILE" lambda_manifest_builder.py
cd ..

echo -e "${GREEN}[SUCCESS]${NC} Package created: $ZIP_FILE"

# Step 3: Update Lambda function
echo -e "${BLUE}[INFO]${NC} Updating Lambda function: $FUNCTION_NAME"

aws lambda update-function-code \
  --function-name "$FUNCTION_NAME" \
  --zip-file "fileb://$ZIP_FILE" \
  --output json > /tmp/lambda-update-result.json

# Extract version
VERSION=$(jq -r '.Version' /tmp/lambda-update-result.json)
LAST_MODIFIED=$(jq -r '.LastModified' /tmp/lambda-update-result.json)

echo -e "${GREEN}[SUCCESS]${NC} Lambda updated!"
echo -e "  Version: $VERSION"
echo -e "  Last Modified: $LAST_MODIFIED"

# Step 4: Wait for update to complete
echo -e "${BLUE}[INFO]${NC} Waiting for update to complete..."
sleep 2

aws lambda wait function-updated \
  --function-name "$FUNCTION_NAME"

echo -e "${GREEN}[SUCCESS]${NC} Update complete and function is ready!"

# Optional: Invoke test
read -p "Do you want to test the function? (yes/no): " TEST_NOW

if [ "$TEST_NOW" = "yes" ]; then
    echo -e "${BLUE}[INFO]${NC} Testing function with empty event..."

    aws lambda invoke \
      --function-name "$FUNCTION_NAME" \
      --payload '{"Records":[]}' \
      /tmp/test-response.json

    echo -e "${BLUE}[INFO]${NC} Response:"
    cat /tmp/test-response.json | jq .
fi

echo -e "${GREEN}[DONE]${NC} Manifest Builder updated successfully!"
