#!/bin/bash

# Fix Glue Job Output Bucket
# Updates the Glue job to use the correct output bucket

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
JOB_NAME="${STACK_NAME}-streaming-processor"
CORRECT_BUCKET="ndjson-parquet-output-${AWS_ACCOUNT_ID}"

echo -e "${GREEN}Fixing Glue Job Output Bucket${NC}"
echo "Job: $JOB_NAME"
echo "Correct bucket: $CORRECT_BUCKET"
echo ""

# Get current configuration
echo -e "${YELLOW}Current Glue job configuration:${NC}"
CURRENT_CONFIG=$(aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --output json)

CURRENT_BUCKET=$(echo "$CURRENT_CONFIG" | python -c "import sys, json; data=json.load(sys.stdin); print(data['Job']['DefaultArguments'].get('--OUTPUT_BUCKET', 'NOT SET'))")
echo "Current OUTPUT_BUCKET: $CURRENT_BUCKET"
echo ""

if [ "$CURRENT_BUCKET" == "$CORRECT_BUCKET" ]; then
    echo -e "${GREEN}✓ Output bucket is already correct!${NC}"
    exit 0
fi

# Update the job
echo -e "${YELLOW}Updating Glue job configuration...${NC}"

# Extract necessary fields
ROLE=$(echo "$CURRENT_CONFIG" | python -c "import sys, json; print(json.load(sys.stdin)['Job']['Role'])")
SCRIPT_LOCATION=$(echo "$CURRENT_CONFIG" | python -c "import sys, json; print(json.load(sys.stdin)['Job']['Command']['ScriptLocation'])")

# Get current default arguments and update OUTPUT_BUCKET
DEFAULT_ARGS=$(echo "$CURRENT_CONFIG" | python -c "
import sys, json
data = json.load(sys.stdin)
args = data['Job'].get('DefaultArguments', {})
args['--OUTPUT_BUCKET'] = '${CORRECT_BUCKET}'
print(json.dumps(args))
")

# Update the job
aws glue update-job \
  --job-name "$JOB_NAME" \
  --job-update "{
    \"Role\": \"$ROLE\",
    \"Command\": {
      \"Name\": \"glueetl\",
      \"ScriptLocation\": \"$SCRIPT_LOCATION\",
      \"PythonVersion\": \"3\"
    },
    \"DefaultArguments\": $DEFAULT_ARGS
  }" \
  --region $REGION

echo ""
echo -e "${GREEN}✓ Glue job updated successfully!${NC}"
echo ""
echo "New configuration:"
aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query 'Job.DefaultArguments."--OUTPUT_BUCKET"' \
  --output text

echo ""
echo "Next steps:"
echo "  1. Run a test: ./test-end-to-end.sh"
echo "  2. Or manually: ./run-glue-batch.sh"
echo ""
