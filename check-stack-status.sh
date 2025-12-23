#!/bin/bash
echo "Checking stack status..."
aws cloudformation describe-stacks \
    --stack-name ndjson-parquet-sqs \
    --region us-east-1 \
    --query 'Stacks[0].[StackStatus,StackStatusReason]' \
    --output table 2>&1

echo ""
echo "Checking if any resources were created..."
aws cloudformation list-stack-resources \
    --stack-name ndjson-parquet-sqs \
    --region us-east-1 \
    --query 'StackResourceSummaries[*].[LogicalResourceId,ResourceType,ResourceStatus]' \
    --output table 2>&1 | head -30
