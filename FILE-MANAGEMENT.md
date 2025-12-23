# File Management Guide

## Project Cleanup and Manifest Lifecycle Management

This document outlines the file organization, cleanup procedures, and manifest lifecycle for the NDJSON to Parquet pipeline project.

---

## Quick Reference

```bash
# Preview what will be deleted
./teardown.sh --dry-run --full

# Clean only temporary/debug files
./teardown.sh --temp-only

# Full cleanup (stack + files)
./teardown.sh --full

# Delete stack only
./teardown.sh --stack-only
```

---

## File Categories

### 1. **KEEP - Core Project Files**

These are essential project files that should always be preserved:

#### Application Code
- `app/lambda_manifest_builder.py` - Manifest builder Lambda function
- `app/lambda_control_plane.py` - Control plane Lambda function
- `app/glue_streaming_ndjson_to_parquet.py` - Glue job script

#### Configuration
- `configurations/cloudformation-sqs-manifest.yaml` - Main CloudFormation template
- `configurations/parameters.json` - Deployment parameters
- `deploy.sh` - Main deployment script
- `deploy.ps1` - PowerShell deployment script

#### Documentation
- `Documentations/README-SQS-MANIFEST.md` - SQS manifest architecture
- `Documentations/DEPLOYMENT-GUIDE.md` - Deployment instructions
- `Documentations/DLQ-ANALYSIS.md` - Dead letter queue analysis
- `Documentations/CHANGELOG.md` - Change history
- `Documentations/GLUE-STREAMING-EXPLAINED.md` - Glue streaming details
- `Documentations/TEST-DATA-GENERATOR-SETUP.md` - Test data setup

#### Diagrams
- `diagrams/sqs-manifest-architecture.mermaid` - Architecture diagram

#### Generators (Optional - Keep if needed for testing)
- `generators/scripts/generate-ndjson-files.ps1` - Test data generator
- `generators/scripts/generate-ndjson-files.bat` - Batch generator
- `generators/scripts/generate-25kb-ndjson-files.ps1` - 25KB file generator
- `generators/scripts/generate-25kb-ndjson-files.bat` - 25KB batch generator
- `generators/scripts/generate-25kb-ndjson-files-2.bat` - Alternative generator

---

### 2. **DELETE - Temporary and Debug Files**

These files were created during development/debugging and should be removed:

#### Debug Output Files
- `current-error.json` - Latest error dump
- `latest-failure.json` - Previous failure log
- `newest-failure.json` - Most recent failure
- `stack-events.txt` - CloudFormation event log
- `stack-resources.txt` - Stack resource list
- `notes.txt` - Development notes
- `nul` - Empty placeholder file

#### Debug Scripts
- `check-latest-error.sh` - Error checking utility
- `check-stack-status.sh` - Stack status checker
- `cleanup-and-deploy.sh` - Combined cleanup/deploy
- `deploy-fresh.sh` - Fresh deployment script
- `get-current-error.sh` - Current error fetcher
- `get-errors.sh` - Error log fetcher
- `quick-redeploy.sh` - Quick redeploy utility
- `update-lambdas.sh` - Lambda update script
- `verify-deployment.sh` - Deployment verifier
- `view-logs.sh` - Log viewer

#### Temporary Directories
- `configurations/temp/` - Temporary CloudFormation files
  - `cloudformation-output.json`
  - `cloudformation-sqs-manifest copy.yaml`
  - `cloudformation-sqs-manifest-app.yaml`
  - `cloudformation-sqs-manifest-db.yaml`
  - `cloudformation-sqs-manifest-iam.yaml`
  - `cloudformation-sqs-manifest-s3.yaml`
  - `cloudformation-sqs-manifest-sqs.yaml`
  - `cloudformation-sqs-manifest.yaml`
  - `parameters-old.json`
  - `stack-events-log.json`

#### Build Artifacts
- `build/` - Build output directory
  - `build/cloudformation-modified.yaml`
  - `build/lambda/control-plane.zip`
  - `build/lambda/manifest-builder.zip`

#### Generated Test Data (Optional)
- `2025-12-21-test0001.ndjson` through `2025-12-21-test0006.ndjson`
- Any other `*.ndjson` files in root directory

---

### 3. **CONDITIONAL - Archive/Package Files**

Consider keeping or archiving:

- `zip/ndjson-parquet-pipeline-v1.1.0/` - Versioned release package
  - Contains snapshot of project at v1.1.0
  - Useful for rollback or distribution
  - Can be archived or kept for reference

---

## Manifest Lifecycle Management

### Manifest File Locations

1. **S3 Input Bucket** (`ndjson-input-{account-id}`)
   - Raw NDJSON files uploaded here
   - Monitored by S3 Event Notifications

2. **Manifest Bucket** (`ndjson-manifests-{account-id}`)
   - Manifest files created by Manifest Builder Lambda
   - Format: `manifest-{timestamp}.json`
   - Contains list of NDJSON files to process

3. **Processing Queue** (SQS)
   - Manifest Builder Queue: Receives S3 events
   - Control Plane Queue: Receives manifest messages

### Manifest Lifecycle States

```
1. NDJSON Upload → S3 Input Bucket
   ↓
2. S3 Event → Manifest Builder Queue
   ↓
3. Lambda creates manifest → Manifest Bucket
   ↓
4. Manifest message → Control Plane Queue
   ↓
5. Control Plane triggers Glue Job
   ↓
6. Glue processes files → Parquet Output
   ↓
7. Success: Delete manifest and NDJSON files
   Failure: Move to Quarantine, send to DLQ
```

### Manifest Cleanup Process

The manifest lifecycle is managed automatically by the system:

1. **Successful Processing**
   - NDJSON files deleted from input bucket
   - Manifest file deleted from manifest bucket
   - SQS messages deleted from queues

2. **Failed Processing**
   - NDJSON files moved to quarantine bucket
   - Manifest retained for debugging
   - Messages sent to Dead Letter Queue (DLQ)

3. **Manual Cleanup** (if needed)

```bash
# List manifests
aws s3 ls s3://ndjson-manifests-{account-id}/

# Delete old manifests (example: older than 7 days)
aws s3 ls s3://ndjson-manifests-{account-id}/ | \
  awk '{print $4}' | \
  xargs -I {} aws s3 rm s3://ndjson-manifests-{account-id}/{}

# Check DLQ for failed manifests
aws sqs receive-message \
  --queue-url $(aws sqs get-queue-url --queue-name ControlPlaneDLQ-ndjson-parquet --query 'QueueUrl' --output text) \
  --max-number-of-messages 10

# Purge DLQ (careful!)
aws sqs purge-queue \
  --queue-url $(aws sqs get-queue-url --queue-name ControlPlaneDLQ-ndjson-parquet --query 'QueueUrl' --output text)
```

---

## Cleanup Workflows

### Workflow 1: Development Cleanup (Keep Stack)

Use when you want to clean up debug files but keep AWS infrastructure running:

```bash
./teardown.sh --temp-only
```

This removes:
- Debug scripts
- Error logs
- Temporary configurations
- Build artifacts
- Generated test data

### Workflow 2: Complete Teardown

Use when completely shutting down the project:

```bash
# Preview first
./teardown.sh --dry-run --full

# Execute
./teardown.sh --full
```

This removes:
- All debug files
- CloudFormation stack
- All AWS resources

### Workflow 3: Stack Refresh

Use when you want to recreate the stack:

```bash
# Delete stack
./teardown.sh --stack-only

# Redeploy
./deploy.sh
```

### Workflow 4: Keep Test Data

Use when cleaning up but preserving generated test files:

```bash
./teardown.sh --temp-only --keep-generated
```

---

## Manual Cleanup Commands

If you prefer manual cleanup:

### Remove Debug Files
```bash
rm -f current-error.json latest-failure.json newest-failure.json
rm -f stack-events.txt stack-resources.txt notes.txt nul
```

### Remove Debug Scripts
```bash
rm -f check-latest-error.sh check-stack-status.sh cleanup-and-deploy.sh
rm -f deploy-fresh.sh get-current-error.sh get-errors.sh
rm -f quick-redeploy.sh update-lambdas.sh verify-deployment.sh view-logs.sh
```

### Remove Temporary Configurations
```bash
rm -rf configurations/temp
```

### Remove Build Artifacts
```bash
rm -rf build
```

### Remove Test Data
```bash
rm -f 2025-*.ndjson
```

### Delete CloudFormation Stack
```bash
aws cloudformation delete-stack --stack-name ndjson-parquet-sqs
aws cloudformation wait stack-delete-complete --stack-name ndjson-parquet-sqs
```

---

## Best Practices

1. **Always use `--dry-run` first** to preview deletions
2. **Keep core project files** under version control
3. **Archive release packages** before major changes
4. **Document custom scripts** before deleting
5. **Check DLQ** before deleting stack to investigate failures
6. **Export manifest data** if needed for debugging
7. **Backup S3 buckets** before full teardown
8. **Review costs** - keeping stack running incurs charges

---

## File Organization Recommendations

```
project-root/
├── app/                    # KEEP - Core Lambda functions
├── configurations/         # KEEP - CloudFormation templates
│   └── temp/              # DELETE - Temporary files
├── Documentations/         # KEEP - Project documentation
├── diagrams/              # KEEP - Architecture diagrams
├── generators/            # CONDITIONAL - Test data generators
├── build/                 # DELETE - Build artifacts
├── zip/                   # ARCHIVE - Release packages
├── deploy.sh              # KEEP - Main deployment
├── deploy.ps1             # KEEP - PowerShell deployment
├── teardown.sh            # KEEP - This cleanup script
├── FILE-MANAGEMENT.md     # KEEP - This document
└── *.ndjson              # DELETE - Test data files
```

---

## Recovery

If you accidentally delete important files:

1. **Check git history**: `git status` and `git log`
2. **Restore from git**: `git checkout -- <file>`
3. **Check archive**: Look in `zip/` directory for backups
4. **Redeploy stack**: Use `deploy.sh` to recreate infrastructure

---

## Support

For issues or questions:
- Review deployment logs: `./view-logs.sh` (if still available)
- Check CloudFormation events in AWS Console
- Review DLQ messages for failed processing
- Consult [DEPLOYMENT-GUIDE.md](Documentations/DEPLOYMENT-GUIDE.md)
