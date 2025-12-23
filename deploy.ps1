# NDJSON to Parquet Pipeline Deployment Script (PowerShell)
# This script handles all prerequisites and deploys the CloudFormation stack

$ErrorActionPreference = "Stop"

# Configuration
$STACK_NAME = "ndjson-parquet-sqs"
$TEMPLATE_FILE = "configurations\cloudformation-sqs-manifest.yaml"
$REGION = "us-east-1"
$AWS_ACCOUNT_ID = (aws sts get-caller-identity --query Account --output text)

Write-Host "`n=== Starting deployment for NDJSON to Parquet Pipeline ===" -ForegroundColor Green
Write-Host "Stack Name: $STACK_NAME"
Write-Host "Region: $REGION"
Write-Host "AWS Account: $AWS_ACCOUNT_ID"
Write-Host ""

# Step 1: Check if stack exists and delete if needed
Write-Host "`nStep 1: Checking for existing stack..." -ForegroundColor Yellow

try {
    $STACK_STATUS = aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].StackStatus' --output text 2>$null
} catch {
    $STACK_STATUS = "DOES_NOT_EXIST"
}

if ($STACK_STATUS -ne "DOES_NOT_EXIST" -and $STACK_STATUS -ne "") {
    Write-Host "Existing stack found with status: $STACK_STATUS"

    if ($STACK_STATUS -match "ROLLBACK" -or $STACK_STATUS -match "FAILED") {
        Write-Host "Stack is in failed state. Deleting..." -ForegroundColor Red
        aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
        Write-Host "Waiting for stack deletion to complete..."
        aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION
        Write-Host "Stack deleted successfully" -ForegroundColor Green
    } else {
        Write-Host "Stack exists in stable state." -ForegroundColor Yellow
        $response = Read-Host "Do you want to update the existing stack? (y/n)"
        if ($response -ne "y") {
            Write-Host "Deployment cancelled."
            exit 0
        }
    }
} else {
    Write-Host "No existing stack found."
}

# Step 2: Create deployment artifacts bucket
Write-Host "`nStep 2: Setting up deployment artifacts bucket..." -ForegroundColor Yellow
$DEPLOYMENT_BUCKET = "ndjson-parquet-deployment-$AWS_ACCOUNT_ID"

# Check if deployment bucket exists
$bucketExists = aws s3 ls "s3://$DEPLOYMENT_BUCKET" 2>&1
if ($bucketExists -match "NoSuchBucket" -or $LASTEXITCODE -ne 0) {
    Write-Host "Creating deployment bucket: $DEPLOYMENT_BUCKET"
    aws s3 mb "s3://$DEPLOYMENT_BUCKET" --region $REGION

    # Enable versioning
    aws s3api put-bucket-versioning `
        --bucket $DEPLOYMENT_BUCKET `
        --versioning-configuration Status=Enabled `
        --region $REGION
} else {
    Write-Host "Deployment bucket already exists: $DEPLOYMENT_BUCKET"
}

# Step 3: Package and upload Lambda functions
Write-Host "`nStep 3: Packaging Lambda functions..." -ForegroundColor Yellow

# Create build directory
New-Item -ItemType Directory -Force -Path "build\lambda" | Out-Null
Remove-Item -Path "build\lambda\*" -Force -ErrorAction SilentlyContinue

# Package manifest builder
Write-Host "Packaging manifest builder..."
Compress-Archive -Path "app\lambda_manifest_builder.py" `
    -DestinationPath "build\lambda\manifest-builder.zip" -Force

# Package control plane
Write-Host "Packaging control plane..."
Compress-Archive -Path "app\lambda_control_plane.py" `
    -DestinationPath "build\lambda\control-plane.zip" -Force

# Upload to S3
Write-Host "Uploading Lambda packages to S3..."
aws s3 cp build\lambda\manifest-builder.zip "s3://$DEPLOYMENT_BUCKET/lambda/" --region $REGION
aws s3 cp build\lambda\control-plane.zip "s3://$DEPLOYMENT_BUCKET/lambda/" --region $REGION

Write-Host "Lambda functions packaged and uploaded" -ForegroundColor Green

# Step 4: Upload Glue script
Write-Host "`nStep 4: Uploading Glue streaming job script..." -ForegroundColor Yellow

$MANIFEST_BUCKET = "ndjson-manifests-$AWS_ACCOUNT_ID"

# Check if manifest bucket exists
$manifestBucketExists = aws s3 ls "s3://$MANIFEST_BUCKET" 2>&1
if ($manifestBucketExists -match "NoSuchBucket" -or $LASTEXITCODE -ne 0) {
    Write-Host "Pre-creating manifest bucket for script upload: $MANIFEST_BUCKET"
    aws s3 mb "s3://$MANIFEST_BUCKET" --region $REGION
}

# Upload Glue script
aws s3 cp app\glue_streaming_job.py "s3://$MANIFEST_BUCKET/scripts/" --region $REGION
Write-Host "Glue script uploaded to s3://$MANIFEST_BUCKET/scripts/glue_streaming_job.py" -ForegroundColor Green

# Step 5: Validate CloudFormation template
Write-Host "`nStep 5: Validating CloudFormation template..." -ForegroundColor Yellow
aws cloudformation validate-template `
    --template-body file://$TEMPLATE_FILE `
    --region $REGION | Out-Null

Write-Host "Template is valid" -ForegroundColor Green

# Step 6: Deploy CloudFormation stack
Write-Host "`nStep 6: Deploying CloudFormation stack..." -ForegroundColor Yellow

if ($STACK_STATUS -eq "DOES_NOT_EXIST" -or $STACK_STATUS -eq "") {
    Write-Host "Creating new stack..."
    aws cloudformation create-stack `
        --stack-name $STACK_NAME `
        --template-body file://$TEMPLATE_FILE `
        --capabilities CAPABILITY_NAMED_IAM `
        --tags Key=Environment,Value=Production Key=Team,Value=DataEngineering `
        --region $REGION

    Write-Host "Waiting for stack creation to complete..."
    Write-Host "This may take 5-10 minutes..." -ForegroundColor Cyan

    # Wait for stack creation
    $waitResult = aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Stack created successfully!" -ForegroundColor Green
    } else {
        Write-Host "Stack creation failed!" -ForegroundColor Red
        Write-Host "Fetching error details..."
        aws cloudformation describe-stack-events `
            --stack-name $STACK_NAME `
            --region $REGION `
            --query 'StackEvents[?ResourceStatus==``CREATE_FAILED``].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]' `
            --output table
        exit 1
    }
} else {
    Write-Host "Updating existing stack..."
    try {
        aws cloudformation update-stack `
            --stack-name $STACK_NAME `
            --template-body file://$TEMPLATE_FILE `
            --capabilities CAPABILITY_NAMED_IAM `
            --region $REGION
    } catch {
        Write-Host "No updates to perform"
    }
}

# Step 7: Update Lambda function code
Write-Host "`nStep 7: Updating Lambda function code..." -ForegroundColor Yellow

$MANIFEST_BUILDER_FUNCTION = "$STACK_NAME-manifest-builder"
$CONTROL_PLANE_FUNCTION = "$STACK_NAME-control-plane"

Write-Host "Updating manifest builder function..."
aws lambda update-function-code `
    --function-name $MANIFEST_BUILDER_FUNCTION `
    --s3-bucket $DEPLOYMENT_BUCKET `
    --s3-key "lambda/manifest-builder.zip" `
    --region $REGION | Out-Null

Write-Host "Updating control plane function..."
aws lambda update-function-code `
    --function-name $CONTROL_PLANE_FUNCTION `
    --s3-bucket $DEPLOYMENT_BUCKET `
    --s3-key "lambda/control-plane.zip" `
    --region $REGION | Out-Null

Write-Host "Lambda functions updated with actual code" -ForegroundColor Green

# Step 8: Display stack outputs
Write-Host "`nStep 8: Deployment Summary" -ForegroundColor Yellow
Write-Host ""
aws cloudformation describe-stacks `
    --stack-name $STACK_NAME `
    --region $REGION `
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' `
    --output table

Write-Host ""
Write-Host "=== Deployment completed successfully! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Check your email and confirm the SNS subscription"
Write-Host "2. Upload NDJSON files to the input bucket to test the pipeline"
Write-Host "3. Monitor the CloudWatch dashboard for pipeline metrics"
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  View logs: aws logs tail /aws/lambda/$MANIFEST_BUILDER_FUNCTION --follow"
Write-Host "  Check queue: aws sqs get-queue-attributes --queue-url <queue-url> --attribute-names All"
Write-Host ""
