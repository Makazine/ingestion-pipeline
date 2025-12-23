# Manifest Builder - Date Partitioning Strategy

## Overview

The Manifest Builder Lambda (`lambda_manifest_builder.py`) ensures that each manifest contains **only NDJSON files with the same date prefix**. This is critical for proper Glue job partitioning and prevents errors when merging files.

## Why Date Grouping Matters

### Problem Without Date Grouping

If a manifest contains files from different dates:

```json
{
  "fileLocations": [
    {"URIPrefixes": ["s3://bucket/2025-12-20-test0001.ndjson"]},
    {"URIPrefixes": ["s3://bucket/2025-12-21-test0002.ndjson"]},
    {"URIPrefixes": ["s3://bucket/2025-12-22-test0003.ndjson"]}
  ]
}
```

**Glue Job Issues:**
1. **Partition conflicts** - Cannot write to multiple partitions simultaneously
2. **Merge errors** - Cannot merge data with different partition keys
3. **Data corruption** - Files may end up in wrong partitions
4. **Job failures** - Glue job will error out

### Solution: Strict Date Grouping

Each manifest contains only files from a single date:

**Manifest 1 (2025-12-20):**
```json
{
  "fileLocations": [
    {"URIPrefixes": ["s3://bucket/2025-12-20-test0001.ndjson"]},
    {"URIPrefixes": ["s3://bucket/2025-12-20-test0002.ndjson"]},
    {"URIPrefixes": ["s3://bucket/2025-12-20-test0003.ndjson"]}
  ],
  "metadata": {
    "date_prefix": "2025-12-20"
  }
}
```

**Manifest 2 (2025-12-21):**
```json
{
  "fileLocations": [
    {"URIPrefixes": ["s3://bucket/2025-12-21-test0001.ndjson"]},
    {"URIPrefixes": ["s3://bucket/2025-12-21-test0002.ndjson"]}
  ],
  "metadata": {
    "date_prefix": "2025-12-21"
  }
}
```

## How Date Grouping Works

### Step 1: File Validation and Date Extraction

When a file arrives, the manifest builder extracts the date prefix:

```python
# Extract date prefix (yyyy-mm-dd) from filename
date_match = re.match(r'(\d{4}-\d{2}-\d{2})-', filename)
date_prefix = date_match.group(1) if date_match else None
```

**Filename pattern:** `{date_prefix}-{description}.ndjson`

**Examples:**
- ✅ `2025-12-23-test0001-143052.ndjson` → date_prefix: `2025-12-23`
- ✅ `2025-01-15-production-data.ndjson` → date_prefix: `2025-01-15`
- ❌ `myfile.ndjson` → Rejected (no date prefix)
- ❌ `20251223-test.ndjson` → Rejected (wrong format)

**Code location:** [lambda_manifest_builder.py:220-221](../app/lambda_manifest_builder.py#L220-L221)

### Step 2: Group Files by Date

Files are grouped by their date prefix before processing:

```python
def _group_by_date(self, files: List[Dict]) -> Dict[str, List[Dict]]:
    """Group files by date prefix."""
    groups = {}
    for file_info in files:
        date_prefix = file_info['date_prefix']
        if date_prefix not in groups:
            groups[date_prefix] = []
        groups[date_prefix].append(file_info)
    return groups
```

**Result:**
```python
{
  '2025-12-20': [file1, file2, file3],
  '2025-12-21': [file4, file5],
  '2025-12-22': [file6, file7, file8, file9]
}
```

**Code location:** [lambda_manifest_builder.py:276-284](../app/lambda_manifest_builder.py#L276-L284)

### Step 3: Process Each Date Group Separately

Each date group is processed independently:

```python
date_groups = self._group_by_date(pending_files)

for date_prefix, files in date_groups.items():
    manifests_created = self._create_manifests_if_ready(date_prefix, files)
    stats['manifests_created'] += manifests_created
```

**Key points:**
- Each date prefix gets its own lock to prevent race conditions
- Files from different dates never mix in batches
- Each date can have multiple batches if needed

**Code location:** [lambda_manifest_builder.py:191-195](../app/lambda_manifest_builder.py#L191-L195)

### Step 4: Create Batches Within Date Group

Within a single date group, files are batched by size (1GB max):

```python
def _create_batches(self, files: List[Dict]) -> List[List[Dict]]:
    """
    Create batches of files up to max size.

    IMPORTANT: All files in the input list must have the same date_prefix.
    This method is called per date group to ensure proper Glue partitioning.
    """
```

**Example for date `2025-12-20`:**

If there are 600 files @ 3.5MB each = 2.1GB total:
- **Batch 1:** 286 files (1.0 GB) → Manifest 1
- **Batch 2:** 286 files (1.0 GB) → Manifest 2
- **Batch 3:** 28 files (0.1 GB) → Wait for more files (below 50% threshold)

**Code location:** [lambda_manifest_builder.py:407-440](../app/lambda_manifest_builder.py#L407-L440)

### Step 5: Validation Before Manifest Creation

Before creating each manifest, the system validates date consistency:

```python
# CRITICAL: Verify all files have the same date prefix
# This ensures Glue won't error when partitioning
date_prefixes = {f['date_prefix'] for f in files}

if len(date_prefixes) > 1:
    logger.error(f"Manifest creation aborted: Multiple date prefixes in batch: {date_prefixes}")
    return None

if date_prefixes != {date_prefix}:
    logger.error(f"Manifest creation aborted: Files date prefix {date_prefixes} "
               f"doesn't match expected {date_prefix}")
    return None
```

**Safety checks:**
1. ✅ All files have the same date prefix
2. ✅ Date prefix matches expected value
3. ❌ Abort if any inconsistency detected

**Code location:** [lambda_manifest_builder.py:460-470](../app/lambda_manifest_builder.py#L460-L470)

### Step 6: Manifest Storage

Manifests are stored in S3 with date prefix in the path:

```python
manifest_key = f'manifests/{date_prefix}/batch-{batch_idx:04d}-{timestamp}.json'
```

**Examples:**
- `manifests/2025-12-20/batch-0001-20251220-143052.json`
- `manifests/2025-12-20/batch-0002-20251220-143125.json`
- `manifests/2025-12-21/batch-0001-20251221-090530.json`

This organization makes it easy to:
- Track manifests by date
- Debug processing issues
- Clean up old manifests
- Monitor batch creation

**Code location:** [lambda_manifest_builder.py:491](../app/lambda_manifest_builder.py#L491)

## Data Flow Example

### Scenario: Files Arrive for Multiple Dates

**Input: 10 files arrive**
```
2025-12-20-test0001.ndjson  (3.5 MB)
2025-12-20-test0002.ndjson  (3.5 MB)
2025-12-20-test0003.ndjson  (3.5 MB)
2025-12-20-test0004.ndjson  (3.5 MB)
2025-12-21-test0001.ndjson  (3.5 MB)
2025-12-21-test0002.ndjson  (3.5 MB)
2025-12-21-test0003.ndjson  (3.5 MB)
2025-12-22-test0001.ndjson  (3.5 MB)
2025-12-22-test0002.ndjson  (3.5 MB)
2025-12-22-test0003.ndjson  (3.5 MB)
```

**Step 1: Validation**
All files pass validation (correct format, size, date prefix)

**Step 2: Grouping**
```
Date Groups:
  2025-12-20: [4 files, 14 MB total]
  2025-12-21: [3 files, 10.5 MB total]
  2025-12-22: [3 files, 10.5 MB total]
```

**Step 3: DynamoDB Tracking**
Files tracked in DynamoDB with date_prefix as partition key:
```
| date_prefix | file_name               | status  |
|-------------|-------------------------|---------|
| 2025-12-20  | test0001.ndjson        | pending |
| 2025-12-20  | test0002.ndjson        | pending |
| 2025-12-20  | test0003.ndjson        | pending |
| 2025-12-20  | test0004.ndjson        | pending |
| 2025-12-21  | test0001.ndjson        | pending |
...
```

**Step 4: Check Batch Readiness**
- 2025-12-20: 14 MB < 1024 MB (1GB) → Wait for more files
- 2025-12-21: 10.5 MB < 1024 MB → Wait
- 2025-12-22: 10.5 MB < 1024 MB → Wait

**Step 5: More Files Arrive (Next Invocation)**

Assume 300 more files arrive for 2025-12-20:
- Total for 2025-12-20: 304 files × 3.5 MB = 1.064 GB
- Exceeds 1GB threshold ✅

**Step 6: Manifest Creation**

```
Manifest created:
  s3://manifests/2025-12-20/batch-0001-20251220-143052.json

Contents:
  - 293 files from 2025-12-20
  - Total: ~1.02 GB
  - Remaining 11 files wait for next batch
```

**Step 7: DynamoDB Update**
```
| date_prefix | file_name               | status      | manifest_path                    |
|-------------|-------------------------|-------------|----------------------------------|
| 2025-12-20  | test0001.ndjson        | manifested  | s3://manifests/2025-12-20/...   |
| 2025-12-20  | test0002.ndjson        | manifested  | s3://manifests/2025-12-20/...   |
...
```

## DynamoDB Schema for Date Grouping

### Partition Key Strategy

```
Partition Key: date_prefix (String)
Sort Key: file_name (String)
```

**Why this works:**
- All files for a date are in the same partition
- Efficient querying: `date_prefix = '2025-12-20'`
- No cross-partition queries needed
- Supports pagination for large result sets

### Query Pattern

```python
response = table.query(
    KeyConditionExpression='date_prefix = :prefix',
    FilterExpression='#status = :status',
    ExpressionAttributeValues={
        ':prefix': '2025-12-20',
        ':status': 'pending'
    }
)
```

**Result:** All pending files for 2025-12-20

## Distributed Locking Per Date

Each date prefix gets its own lock:

```python
lock = DistributedLock(LOCK_TABLE, date_prefix, LOCK_TTL_SECONDS)

if lock.acquire():
    # Process this date group
    # Other invocations for same date wait
    # Other invocations for different dates proceed independently
```

**Benefits:**
- Prevent race conditions within a date
- Allow parallel processing of different dates
- Avoid duplicate manifests
- Safe concurrent Lambda invocations

**Lock key format:** `LOCK#{date_prefix}`

**Examples:**
- `LOCK#2025-12-20`
- `LOCK#2025-12-21`
- `LOCK#2025-12-22`

## Glue Job Integration

### How Glue Uses Date-Grouped Manifests

When Glue processes a manifest with files from the same date:

```python
# Glue can safely partition by date
df = glue_context.create_dynamic_frame.from_options(
    connection_type="s3",
    connection_options={"paths": manifest_file_locations},
    format="json"
)

# All records go to the same partition
df.write.partitionBy("date").parquet(output_path)
```

**Output structure:**
```
s3://parquet-output/
  date=2025-12-20/
    part-00000.parquet
    part-00001.parquet
  date=2025-12-21/
    part-00000.parquet
  date=2025-12-22/
    part-00000.parquet
```

### What Happens Without Date Grouping

If manifest has mixed dates:

```python
# ERROR: Cannot write to multiple partitions
# Glue tries to write to date=2025-12-20 and date=2025-12-21 simultaneously
# Result: AnalysisException or corrupted data
```

## Testing Date Grouping

### Test Case 1: Single Date

Upload files for one date:
```bash
aws s3 cp 2025-12-20-test0001.ndjson s3://input-bucket/
aws s3 cp 2025-12-20-test0002.ndjson s3://input-bucket/
```

**Expected:** Manifest contains only 2025-12-20 files

### Test Case 2: Multiple Dates

Upload files for different dates:
```bash
aws s3 cp 2025-12-20-test0001.ndjson s3://input-bucket/
aws s3 cp 2025-12-21-test0001.ndjson s3://input-bucket/
aws s3 cp 2025-12-22-test0001.ndjson s3://input-bucket/
```

**Expected:**
- 3 separate date groups created
- Each waits independently for 1GB threshold
- No mixing of dates in manifests

### Test Case 3: Large Batch Single Date

Upload 300 files for same date:
```bash
for i in {1..300}; do
  aws s3 cp "2025-12-20-test$(printf %04d $i).ndjson" s3://input-bucket/
done
```

**Expected:**
- Single manifest created with all files
- All files have date_prefix: 2025-12-20
- Glue processes successfully

### Test Case 4: Invalid Date Format

Upload file without date prefix:
```bash
aws s3 cp myfile.ndjson s3://input-bucket/
```

**Expected:**
- File rejected in validation
- Moved to quarantine bucket
- No manifest created

## Monitoring Date Grouping

### CloudWatch Logs

Look for these log messages:

**Successful grouping:**
```
Date 2025-12-20: 293 pending files (293 existing + 0 new)
Created manifest: s3://manifests/2025-12-20/batch-0001-20251220-143052.json
  with 293 files (1.02GB)
```

**Validation errors:**
```
Manifest creation aborted: Multiple date prefixes in batch: {'2025-12-20', '2025-12-21'}
```

**Waiting for more files:**
```
Not enough data yet: 0.10GB (need 1.00GB)
Holding 11 files (0.04GB) for next batch
```

### DynamoDB Queries

Check files by date:
```bash
aws dynamodb query \
  --table-name FileTrackingTable \
  --key-condition-expression "date_prefix = :date" \
  --expression-attribute-values '{":date":{"S":"2025-12-20"}}'
```

Count manifested files per date:
```bash
aws dynamodb query \
  --table-name FileTrackingTable \
  --key-condition-expression "date_prefix = :date" \
  --filter-expression "#status = :status" \
  --expression-attribute-names '{"#status":"status"}' \
  --expression-attribute-values '{":date":{"S":"2025-12-20"},":status":{"S":"manifested"}}' \
  --select COUNT
```

### S3 Manifest Inspection

View manifests for a specific date:
```bash
aws s3 ls s3://manifest-bucket/manifests/2025-12-20/
```

Verify manifest contents:
```bash
aws s3 cp s3://manifest-bucket/manifests/2025-12-20/batch-0001-20251220-143052.json - | jq .
```

Check all file URIs have same date:
```bash
aws s3 cp s3://manifest-bucket/manifests/2025-12-20/batch-0001-20251220-143052.json - \
  | jq -r '.fileLocations[].URIPrefixes[]' \
  | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' \
  | sort -u
```

**Expected:** Only one date output (2025-12-20)

## Troubleshooting

### Issue: Manifest Has Mixed Dates

**Symptom:** Glue job fails with partition error

**Investigation:**
1. Check CloudWatch logs for "Multiple date prefixes" errors
2. Inspect manifest file contents
3. Verify DynamoDB entries

**Solution:**
- This should never happen with current validation
- If it does, it indicates a bug in the validation logic
- Check code at lines 460-470 in lambda_manifest_builder.py

### Issue: Files Not Batching

**Symptom:** Files tracked but no manifests created

**Investigation:**
1. Check total size: Must reach 1GB (or 50% for final batch)
2. Check date grouping: Are files spread across many dates?
3. Check locks: Is another invocation holding the lock?

**Solution:**
- Wait for more files to reach threshold
- Or lower MAX_BATCH_SIZE_GB environment variable

### Issue: Wrong Date in Partition

**Symptom:** Parquet files in wrong date partition

**Investigation:**
1. Check source NDJSON filename format
2. Verify manifest metadata.date_prefix matches filenames
3. Check Glue job partition column

**Solution:**
- Ensure NDJSON files follow naming convention: `yyyy-mm-dd-*`
- Verify Glue job extracts date correctly
- Check Glue partition column matches manifest date_prefix

## Best Practices

1. **Consistent Filename Format**
   - Always use `yyyy-mm-dd-` prefix
   - Example: `2025-12-23-production-batch001.ndjson`

2. **Upload Files in Batches**
   - Upload all files for a date together
   - Reduces wait time for 1GB threshold

3. **Monitor Lock Timeouts**
   - Default: 5 minutes
   - Increase if processing takes longer

4. **Set Appropriate Batch Size**
   - 1GB default works for most cases
   - Adjust based on Glue job performance

5. **Regular Cleanup**
   - Delete old manifests after processing
   - Clean up DynamoDB entries (TTL: 7 days default)

6. **Test Date Grouping**
   - Always test with multiple dates
   - Verify no cross-contamination

## Summary

The Manifest Builder ensures date grouping through:

1. ✅ **Filename validation** - Extracts and validates date prefix
2. ✅ **Explicit grouping** - Groups files by date before processing
3. ✅ **Isolated processing** - Each date processed independently
4. ✅ **Lock per date** - Prevents race conditions within date
5. ✅ **Validation checks** - Double-checks before manifest creation
6. ✅ **Organized storage** - Manifests stored by date in S3

This architecture guarantees that Glue jobs never receive mixed-date manifests, preventing partition errors and data corruption.
