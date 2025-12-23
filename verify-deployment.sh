#!/bin/bash
echo "=== CloudFormation Stack Outputs ==="
aws cloudformation describe-stacks \
    --stack-name ndjson-parquet-sqs \
    --region us-east-1 \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table

echo ""
echo "=== All Stack Resources ==="
aws cloudformation list-stack-resources \
    --stack-name ndjson-parquet-sqs \
    --region us-east-1 \
    --query 'StackResourceSummaries[*].[LogicalResourceId,ResourceType,ResourceStatus]' \
    --output table
