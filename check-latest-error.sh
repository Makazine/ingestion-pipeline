#!/bin/bash
aws cloudformation describe-stack-events \
    --stack-name ndjson-parquet-sqs \
    --region us-east-1 \
    --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`]' \
    --output json > newest-failure.json

cat newest-failure.json
