#!/bin/bash
echo "Getting latest failure details..."
aws cloudformation describe-stack-events \
    --stack-name ndjson-parquet-sqs \
    --region us-east-1 \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]' \
    --output table | head -30
