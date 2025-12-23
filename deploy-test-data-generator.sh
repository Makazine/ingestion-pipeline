#!/bin/bash

# deploy-test-data-generator.sh
# Deploys the Test Data Generator Lambda function with IAM role

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
STACK_NAME="ndjson-parquet-test-data-generator"
TEMPLATE_FILE="configurations/lambda-test-data-generator-full.yaml"
PARAMETERS_FILE="configurations/parameters-test-data-generator.json"
REGION="${AWS_REGION:-us-east-1}"

# Lambda packaging
LAMBDA_SOURCE="app/lambda_test_data_generator.py"
LAMBDA_ZIP="build/lambda/test-data-generator.zip"
BUILD_DIR="build/lambda"

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
    echo ""
}

# Step 1: Validate prerequisites
print_header "Step 1: Validating Prerequisites"

if [ ! -f "$LAMBDA_SOURCE" ]; then
    print_error "Lambda source file not found: $LAMBDA_SOURCE"
    exit 1
fi
print_success "Lambda source file found"

if [ ! -f "$TEMPLATE_FILE" ]; then
    print_error "CloudFormation template not found: $TEMPLATE_FILE"
    exit 1
fi
print_success "CloudFormation template found"

if [ ! -f "$PARAMETERS_FILE" ]; then
    print_error "Parameters file not found: $PARAMETERS_FILE"
    exit 1
fi
print_success "Parameters file found"

# Check AWS credentials
if ! aws sts get-caller-identity &>/dev/null; then
    print_error "AWS credentials not configured"
    exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
print_success "AWS credentials valid (Account: $ACCOUNT_ID)"

# Step 2: Package Lambda function
print_header "Step 2: Packaging Lambda Function"

mkdir -p "$BUILD_DIR"

print_status "Creating deployment package: $LAMBDA_ZIP"
cd "$(dirname "$LAMBDA_SOURCE")"
zip -q "../$LAMBDA_ZIP" "$(basename "$LAMBDA_SOURCE")"
cd - > /dev/null

print_success "Lambda package created: $LAMBDA_ZIP"
ls -lh "$LAMBDA_ZIP"

# Step 3: Upload Lambda package to S3
print_header "Step 3: Uploading Lambda Package to S3"

# Get S3 bucket from parameters
CODE_BUCKET=$(jq -r '.[] | select(.ParameterKey=="LambdaCodeS3Bucket") | .ParameterValue' "$PARAMETERS_FILE")
CODE_KEY=$(jq -r '.[] | select(.ParameterKey=="LambdaCodeS3Key") | .ParameterValue' "$PARAMETERS_FILE")

print_status "Uploading to s3://$CODE_BUCKET/$CODE_KEY"

if aws s3 ls "s3://$CODE_BUCKET" &>/dev/null; then
    aws s3 cp "$LAMBDA_ZIP" "s3://$CODE_BUCKET/$CODE_KEY"
    print_success "Lambda package uploaded to S3"
else
    print_error "S3 bucket does not exist: $CODE_BUCKET"
    print_status "Creating bucket: $CODE_BUCKET"
    aws s3 mb "s3://$CODE_BUCKET" --region "$REGION"
    aws s3 cp "$LAMBDA_ZIP" "s3://$CODE_BUCKET/$CODE_KEY"
    print_success "Bucket created and Lambda package uploaded"
fi

# Step 4: Validate CloudFormation template
print_header "Step 4: Validating CloudFormation Template"

print_status "Validating template: $TEMPLATE_FILE"
aws cloudformation validate-template \
    --template-body "file://$TEMPLATE_FILE" \
    --region "$REGION" > /dev/null

print_success "Template is valid"

# Step 5: Deploy CloudFormation stack
print_header "Step 5: Deploying CloudFormation Stack"

if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &>/dev/null; then
    print_warning "Stack exists, updating: $STACK_NAME"
    OPERATION="update"

    aws cloudformation update-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://$TEMPLATE_FILE" \
        --parameters "file://$PARAMETERS_FILE" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION" || {
            if [[ $? -eq 254 ]]; then
                print_warning "No updates to perform"
                OPERATION="none"
            else
                print_error "Stack update failed"
                exit 1
            fi
        }
else
    print_status "Creating new stack: $STACK_NAME"
    OPERATION="create"

    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body "file://$TEMPLATE_FILE" \
        --parameters "file://$PARAMETERS_FILE" \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION"
fi

# Step 6: Wait for stack operation to complete
if [ "$OPERATION" != "none" ]; then
    print_header "Step 6: Waiting for Stack ${OPERATION^} to Complete"

    print_status "Waiting for stack ${OPERATION}... (this may take a few minutes)"

    if [ "$OPERATION" = "create" ]; then
        aws cloudformation wait stack-create-complete \
            --stack-name "$STACK_NAME" \
            --region "$REGION"
    elif [ "$OPERATION" = "update" ]; then
        aws cloudformation wait stack-update-complete \
            --stack-name "$STACK_NAME" \
            --region "$REGION"
    fi

    print_success "Stack ${OPERATION} complete!"
else
    print_header "Step 6: Stack Status"
fi

# Step 7: Display stack outputs
print_header "Step 7: Deployment Summary"

OUTPUTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs' \
    --output table)

echo "$OUTPUTS"

# Get function name for testing
FUNCTION_NAME=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`TestDataGeneratorFunctionName`].OutputValue' \
    --output text)

print_success "Deployment complete!"

# Step 8: Test the function
print_header "Step 8: Testing Lambda Function"

print_status "Creating test event..."
cat > /tmp/test-event.json <<EOF
{
  "file_count": 2,
  "date_prefix": "$(date +%Y-%m-%d)",
  "target_size_mb": 1.0
}
EOF

print_status "Test event:"
cat /tmp/test-event.json | jq .

echo ""
read -p "Do you want to test the Lambda function now? (yes/no): " TEST_NOW

if [ "$TEST_NOW" = "yes" ]; then
    print_status "Invoking Lambda function..."

    aws lambda invoke \
        --function-name "$FUNCTION_NAME" \
        --payload file:///tmp/test-event.json \
        --region "$REGION" \
        /tmp/lambda-response.json

    echo ""
    print_status "Lambda response:"
    cat /tmp/lambda-response.json | jq .

    print_success "Test complete!"
else
    print_status "Skipping test. You can test manually with:"
    echo ""
    echo "  aws lambda invoke \\"
    echo "    --function-name $FUNCTION_NAME \\"
    echo "    --payload file:///tmp/test-event.json \\"
    echo "    --region $REGION \\"
    echo "    response.json && cat response.json | jq ."
fi

# Summary
print_header "Deployment Complete"

echo "Stack Name: $STACK_NAME"
echo "Function Name: $FUNCTION_NAME"
echo "Region: $REGION"
echo ""
echo "Next steps:"
echo "  1. Test the function with different parameters"
echo "  2. Set up EventBridge schedule for automated generation (optional)"
echo "  3. Monitor CloudWatch logs and metrics"
echo ""

print_success "All done!"
