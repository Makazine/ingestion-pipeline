#!/bin/bash
aws cloudformation describe-stack-events \
    --stack-name ndjson-parquet-sqs \
    --region us-east-1 \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]' \
    --output table > latest-errors.txt 2>&1

cat latest-errors.txt
