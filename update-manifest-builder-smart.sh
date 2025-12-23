#!/bin/bash

# update-manifest-builder-smart.sh
# Auto-detects function name and updates Manifest Builder Lambda

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
LAMBDA_FILE="app/lambda_manifest_builder.py"
BUILD_DIR="build/lambda"
ZIP_FILE="$BUILD_DIR/manifest-builder.zip"

echo -e "${BLUE}[INFO]${NC} Auto-detecting Manifest Builder Lambda function..."

# Method 1: Try to get from CloudFormation stack
FUNCTION_NAME=$(aws cloudformation describe-stack-resources \
  --stack-name "$STACK_NAME" \
  --query 'StackResources[?LogicalResourceId==`ManifestBuilderFunction`].PhysicalResourceId' \
  --output text 2>/dev/null || echo "")

# Method 2: If not found, search by pattern
if [ -z "$FUNCTION_NAME" ]; then
  echo -e "${YELLOW}[WARNING]${NC} Could not find function via CloudFormation, searching by pattern..."

  FUNCTION_NAME=$(aws lambda list-functions \
    --query 'Functions[?contains(FunctionName, `Manifest`) || contains(FunctionName, `manifest`)].FunctionName' \
    --output text 2>/dev/null | head -1 || echo "")
fi

# Method 3: Manual input
if [ -z "$FUNCTION_NAME" ]; then
  echo -e "${YELLOW}[WARNING]${NC} Could not auto-detect function name"
  echo ""
  echo "Please list your Lambda functions:"
  aws lambda list-functions --query 'Functions[].FunctionName' --output table
  echo ""
  read -p "Enter the Manifest Builder function name: " FUNCTION_NAME
fi

if [ -z "$FUNCTION_NAME" ]; then
  echo -e "${RED}[ERROR]${NC} No function name provided. Exiting."
  exit 1
fi

echo -e "${GREEN}[SUCCESS]${NC} Found function: $FUNCTION_NAME"
echo ""

# Verify function exists
echo -e "${BLUE}[INFO]${NC} Verifying function exists..."
if ! aws lambda get-function --function-name "$FUNCTION_NAME" &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Function '$FUNCTION_NAME' not found!"
  exit 1
fi

echo -e "${GREEN}[SUCCESS]${NC} Function verified"
echo ""

# Step 1: Create build directory
mkdir -p "$BUILD_DIR"

# Step 2: Package Lambda
echo -e "${BLUE}[INFO]${NC} Packaging Lambda function..."
cd app
zip -q "../$ZIP_FILE" lambda_manifest_builder.py
cd ..

echo -e "${GREEN}[SUCCESS]${NC} Package created: $ZIP_FILE"
ls -lh "$ZIP_FILE"
echo ""

# Step 3: Update Lambda function
echo -e "${BLUE}[INFO]${NC} Updating Lambda function: $FUNCTION_NAME"

aws lambda update-function-code \
  --function-name "$FUNCTION_NAME" \
  --zip-file "fileb://$ZIP_FILE" \
  --output json > /tmp/lambda-update-result.json

# Extract version
VERSION=$(jq -r '.Version' /tmp/lambda-update-result.json 2>/dev/null || echo "unknown")
LAST_MODIFIED=$(jq -r '.LastModified' /tmp/lambda-update-result.json 2>/dev/null || echo "unknown")
CODE_SIZE=$(jq -r '.CodeSize' /tmp/lambda-update-result.json 2>/dev/null || echo "unknown")

echo -e "${GREEN}[SUCCESS]${NC} Lambda updated!"
echo -e "  Function: $FUNCTION_NAME"
echo -e "  Version: $VERSION"
echo -e "  Code Size: $CODE_SIZE bytes"
echo -e "  Last Modified: $LAST_MODIFIED"
echo ""

# Step 4: Wait for update to complete
echo -e "${BLUE}[INFO]${NC} Waiting for update to complete..."

aws lambda wait function-updated \
  --function-name "$FUNCTION_NAME"

echo -e "${GREEN}[SUCCESS]${NC} Update complete and function is ready!"
echo ""

# Step 5: Display current configuration
echo -e "${BLUE}[INFO]${NC} Current function configuration:"
aws lambda get-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --query '{Runtime:Runtime,Memory:MemorySize,Timeout:Timeout,Handler:Handler,Environment:Environment.Variables}' \
  --output json | jq .

echo ""

# Optional: Invoke test
read -p "Do you want to test the function with an empty event? (yes/no): " TEST_NOW

if [ "$TEST_NOW" = "yes" ]; then
    echo -e "${BLUE}[INFO]${NC} Testing function with empty Records array..."

    echo '{"Records":[]}' > /tmp/test-payload.json

    aws lambda invoke \
      --function-name "$FUNCTION_NAME" \
      --payload file:///tmp/test-payload.json \
      /tmp/test-response.json

    echo ""
    echo -e "${BLUE}[INFO]${NC} Response:"
    cat /tmp/test-response.json | jq . || cat /tmp/test-response.json

    echo ""

    # Check CloudWatch logs
    read -p "Do you want to view the latest CloudWatch logs? (yes/no): " VIEW_LOGS

    if [ "$VIEW_LOGS" = "yes" ]; then
        echo -e "${BLUE}[INFO]${NC} Fetching latest logs..."

        LOG_GROUP="/aws/lambda/$FUNCTION_NAME"

        # Get latest log stream
        LATEST_STREAM=$(aws logs describe-log-streams \
          --log-group-name "$LOG_GROUP" \
          --order-by LastEventTime \
          --descending \
          --max-items 1 \
          --query 'logStreams[0].logStreamName' \
          --output text 2>/dev/null || echo "")

        if [ -n "$LATEST_STREAM" ]; then
            echo -e "${BLUE}[INFO]${NC} Log stream: $LATEST_STREAM"
            echo ""

            aws logs get-log-events \
              --log-group-name "$LOG_GROUP" \
              --log-stream-name "$LATEST_STREAM" \
              --limit 20 \
              --query 'events[].message' \
              --output text
        else
            echo -e "${YELLOW}[WARNING]${NC} No log streams found"
        fi
    fi
fi

echo ""
echo -e "${GREEN}[DONE]${NC} Manifest Builder Lambda updated successfully!"
echo ""
echo "Function name: $FUNCTION_NAME"
echo "Package: $ZIP_FILE"
echo ""
echo "To manually test, use:"
echo "  aws lambda invoke --function-name $FUNCTION_NAME --payload '{\"Records\":[]}' response.json"
