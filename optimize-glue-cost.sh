#!/bin/bash

# Optimize Glue Job for Cost Savings
# Reduces workers and switches to batch mode for testing

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

STACK_NAME="ndjson-parquet-sqs"
REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
JOB_NAME="${STACK_NAME}-streaming-processor"
MANIFEST_BUCKET="ndjson-manifests-${AWS_ACCOUNT_ID}"
OUTPUT_BUCKET="ndjson-parquet-output-${AWS_ACCOUNT_ID}"
DEPLOYMENT_BUCKET="ndjson-parquet-deployment-${AWS_ACCOUNT_ID}"

echo -e "${RED}===== COST OPTIMIZATION =====${NC}"
echo "Reducing Glue job from 10 workers to 2 workers"
echo "This will reduce cost from ~\$4.40/hour to ~\$0.88/hour (80% savings!)"
echo ""

# First, stop any running jobs
echo -e "${YELLOW}Step 1: Stopping any running Glue jobs...${NC}"
RUNNING_JOBS=$(aws glue get-job-runs \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --query "JobRuns[?JobRunState=='RUNNING'].Id" \
  --output text)

if [ ! -z "$RUNNING_JOBS" ]; then
    echo "Found running jobs: $RUNNING_JOBS"
    for JOB_ID in $RUNNING_JOBS; do
        echo "Stopping job run: $JOB_ID"
        aws glue batch-stop-job-run \
          --job-name "$JOB_NAME" \
          --job-run-ids "$JOB_ID" \
          --region $REGION
    done
    echo -e "${GREEN}✓ Running jobs stopped${NC}"
else
    echo "No running jobs found"
fi
echo ""

# Get current config
echo -e "${YELLOW}Step 2: Updating job configuration for cost savings...${NC}"
JOB_CONFIG=$(aws glue get-job \
  --job-name "$JOB_NAME" \
  --region $REGION \
  --output json)

GLUE_ROLE=$(echo "$JOB_CONFIG" | python -c "import sys, json; print(json.load(sys.stdin)['Job']['Role'])")
SCRIPT_LOCATION="s3://${DEPLOYMENT_BUCKET}/scripts/glue_streaming_job.py"

# Update with cost-optimized settings
aws glue update-job \
  --job-name "$JOB_NAME" \
  --job-update '{
    "Role": "'"${GLUE_ROLE}"'",
    "GlueVersion": "4.0",
    "Command": {
      "Name": "glueetl",
      "ScriptLocation": "'"${SCRIPT_LOCATION}"'",
      "PythonVersion": "3"
    },
    "DefaultArguments": {
      "--job-language": "python",
      "--job-bookmark-option": "job-bookmark-disable",
      "--enable-metrics": "true",
      "--enable-spark-ui": "true",
      "--spark-event-logs-path": "s3://'"${MANIFEST_BUCKET}"'/spark-logs/",
      "--enable-continuous-cloudwatch-log": "true",
      "--enable-continuous-log-filter": "true",
      "--MANIFEST_BUCKET": "'"${MANIFEST_BUCKET}"'",
      "--OUTPUT_BUCKET": "'"${OUTPUT_BUCKET}"'",
      "--COMPRESSION_TYPE": "snappy",
      "--TempDir": "s3://'"${MANIFEST_BUCKET}"'/temp/"
    },
    "MaxRetries": 0,
    "Timeout": 60,
    "WorkerType": "G.1X",
    "NumberOfWorkers": 2,
    "ExecutionProperty": {
      "MaxConcurrentRuns": 1
    }
  }' \
  --region $REGION

echo -e "${GREEN}✓ Job optimized for cost savings${NC}"
echo ""

echo -e "${GREEN}===== OPTIMIZATION COMPLETE =====${NC}"
echo ""
echo "Cost savings applied:"
echo "  ✓ Workers reduced: 10 → 2 (80% cost reduction)"
echo "  ✓ Timeout reduced: 2880 min (48 hrs) → 60 min (1 hr)"
echo "  ✓ All running jobs stopped"
echo ""
echo "New hourly cost: ~\$0.88/hour (was ~\$4.40/hour)"
echo ""
echo -e "${YELLOW}IMPORTANT RECOMMENDATIONS:${NC}"
echo ""
echo "1. DO NOT run in streaming mode for testing"
echo "   - Streaming runs 24/7 until manually stopped"
echo "   - Use batch mode instead (process one manifest at a time)"
echo ""
echo "2. For testing, process manifests on-demand:"
echo "   - Upload test files to input bucket"
echo "   - Let Lambda create manifests"
echo "   - Manually trigger Glue job with specific manifest"
echo ""
echo "3. Set up billing alerts:"
echo "   aws cloudwatch put-metric-alarm \\"
echo "     --alarm-name high-billing-alert \\"
echo "     --alarm-description 'Alert when estimated charges exceed \$50' \\"
echo "     --metric-name EstimatedCharges \\"
echo "     --namespace AWS/Billing \\"
echo "     --statistic Maximum \\"
echo "     --period 21600 \\"
echo "     --evaluation-periods 1 \\"
echo "     --threshold 50 \\"
echo "     --comparison-operator GreaterThanThreshold"
echo ""
echo "4. When done testing each day, STOP all Glue jobs:"
echo "   ./stop-all-glue-jobs.sh"
echo ""
