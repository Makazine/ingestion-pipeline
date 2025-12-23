# AWS Glue Streaming Job: Deep Dive & Review

## Executive Summary

Your Glue **Streaming Job** is configured to run **24/7**, continuously watching for new manifest files and processing them in micro-batches. Let me explain exactly how this works and review your implementation.

## What is Glue Streaming?

### Traditional Glue Batch vs Glue Streaming

**Glue BATCH (Traditional):**
```
Start Job → Process Data → Write Output → Stop Job → Start Again
       ↓
    Cold Start (30-60 seconds every time)
    Pay per job run
    Higher latency
```

**Glue STREAMING (Your Implementation):**
```
Start Job ONCE → Keep Running 24/7 → Process Continuously
                      ↓
                 No Cold Starts
                 Workers stay warm
                 Lower latency
```

### Why Streaming for Your Use Case?

At **200,000 files/hour** (~55 files/second), you need:
- ✅ **Continuous processing** - No gaps between batches
- ✅ **Low latency** - No 30-60 second cold starts
- ✅ **Efficient resource usage** - Workers stay warm
- ✅ **Predictable costs** - Workers × hours, not jobs × time

**Perfect fit!** Your workload is constant and high-volume.

## How Your Glue Streaming Job Works

### 1. Initialization Phase

```python
# When job starts (ONCE)
sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args['JOB_NAME'], args)

# Configure Spark (ONCE)
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.shuffle.partitions", "100")
# ... other configs
```

**Happens once at job start:**
- Spark context created
- Workers allocated (10 × G.2X)
- Configuration applied
- Stays active for entire job run

### 2. Streaming Loop

```python
# This runs CONTINUOUSLY
manifest_stream_df = (
    spark.readStream
    .format("text")
    .option("maxFilesPerTrigger", 1)  # Process 1 manifest at a time
    .load(manifest_prefix)            # Watch this S3 location
)
```

**What happens:**
```
Minute 0: Check S3 for new manifests → None → Wait
Minute 0.5: Check S3 → Found 1 manifest → Process it
Minute 2: Check S3 → Found 2 manifests → Process 1 (queue the other)
Minute 3: Process queued manifest
Minute 3.5: Check S3 → None → Wait
... continues forever ...
```

### 3. Processing Trigger

```python
query = (
    manifest_stream_df.writeStream
    .foreachBatch(self._process_manifest_batch)  # Process each batch
    .option("checkpointLocation", f"s3://{MANIFEST_BUCKET}/checkpoints/")
    .trigger(processingTime='30 seconds')  # Check every 30 seconds
    .start()
)
```

**Key parameters:**

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `foreachBatch` | Custom function | How to process each micro-batch |
| `checkpointLocation` | S3 path | Where to store processing state |
| `processingTime` | 30 seconds | Check for new data every 30s |
| `maxFilesPerTrigger` | 1 | Process 1 manifest at a time |

### 4. Checkpoint Mechanism (CRITICAL!)

```
S3://manifest-bucket/checkpoints/
├── commits/
│   ├── 0          # Batch 0 completed
│   ├── 1          # Batch 1 completed
│   └── 2          # Batch 2 completed
├── metadata
├── offsets/
│   ├── 0          # Files processed in batch 0
│   ├── 1          # Files processed in batch 1
│   └── 2          # Files processed in batch 2
└── sources/
    └── 0/
```

**What checkpoints do:**
1. **Track processed files** - Never process same manifest twice
2. **Enable recovery** - If job crashes, resume from last checkpoint
3. **Guarantee exactly-once** - Each manifest processed exactly once
4. **Store progress** - Offsets, batch IDs, file listings

**Example checkpoint content:**
```json
{
  "batchId": 42,
  "files": [
    "s3://manifests/2025-12-21/batch-0001.json",
    "s3://manifests/2025-12-21/batch-0002.json"
  ],
  "processed": true,
  "timestamp": "2025-12-21T10:30:00Z"
}
```

### 5. Micro-Batch Processing

Every 30 seconds:

```python
def _process_manifest_batch(batch_df: DataFrame, batch_id: int):
    """
    Called for each micro-batch.
    batch_id increments: 0, 1, 2, 3, ...
    """
    # Get manifests in this batch
    manifest_rows = batch_df.collect()
    
    for row in manifest_rows:
        manifest = json.loads(row.value)
        
        # 1. Extract file paths from manifest (~286 files)
        file_paths = extract_file_paths(manifest)
        
        # 2. Read all NDJSON files in parallel
        df = spark.read.json(file_paths)
        
        # 3. Transform (cast to string)
        df = cast_all_to_string(df)
        
        # 4. Write Parquet
        df.write.parquet(output_path)
```

**Timeline for one batch:**
```
T+0s:   Detect new manifest
T+1s:   Read manifest file from S3
T+2s:   Extract 286 file paths
T+5s:   Spark reads all 286 NDJSON files in parallel
T+60s:  Data loaded into memory
T+90s:  Transformations applied
T+120s: Write Parquet to S3
T+150s: Update checkpoint
T+150s: Mark batch complete → Ready for next batch
```

**Total: ~2.5 minutes per 1GB batch** (as expected!)

### 6. Parallel Processing

Your 10 workers (G.2X) process **in parallel:**

```
Worker 1: Processing file 1-29
Worker 2: Processing file 30-58
Worker 3: Processing file 59-87
...
Worker 10: Processing file 262-286
```

**Spark partitioning:**
- Input: 286 files → Spark creates ~100 partitions (shuffle.partitions=100)
- Processing: 10 workers × 8 cores each = 80 concurrent tasks
- Output: Coalesced to ~8 files (1GB ÷ 128MB target)

## Code Review: Your Glue Streaming Job

### Excellent Design Patterns ✅

#### 1. Configuration Optimization
```python
def _configure_spark(self):
    # Adaptive execution - EXCELLENT!
    self.spark.conf.set("spark.sql.adaptive.enabled", "true")
    self.spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
    
    # Parquet optimization - PERFECT!
    self.spark.conf.set("spark.sql.parquet.compression.codec", "snappy")
    self.spark.conf.set("spark.sql.files.maxPartitionBytes", "134217728")  # 128MB
    
    # Shuffle partitions - GOOD for 1GB batches!
    self.spark.conf.set("spark.sql.shuffle.partitions", "100")
```

**Why these are good:**
- Adaptive execution → Optimizes partition sizes automatically
- 128MB target → Ideal for S3 reads/writes
- 100 shuffle partitions → Good balance for 10 workers

#### 2. Error Handling
```python
try:
    df = self.spark.read.json(file_paths, multiLine=False)
    # ... processing ...
except Exception as e:
    logger.error(f"Error processing manifest: {str(e)}")
    raise  # Fails the micro-batch, will retry from checkpoint
```

**Why this is good:**
- Fails fast on errors
- Checkpoint ensures no data loss
- Raises exception to trigger alerts

#### 3. Efficient File Reading
```python
# Read all files at once - EXCELLENT!
df = self.spark.read.json(file_paths, multiLine=False)
```

**Why this is good:**
- Single read operation for all 286 files
- Spark parallelizes automatically
- Minimizes S3 API calls

#### 4. Coalescing for Output
```python
# Calculate optimal partitions
estimated_size_mb = record_count / 1024
num_partitions = max(int(estimated_size_mb / 128), 1)

df_coalesced = df.coalesce(num_partitions)
```

**Why this is good:**
- Targets 128MB output files
- Avoids too many small files
- Uses coalesce (not repartition) → No shuffle needed

### Areas for Potential Improvement

#### 1. Checkpoint Cleanup (Optional)

**Current:** Checkpoints accumulate forever

**Recommendation:**
```python
# Add cleanup of old checkpoints (>7 days)
.option("cleanSource", "archive")  # Archive old files
.option("sourceArchiveDir", "s3://bucket/archive/")
```

**Benefit:** Saves S3 storage costs

#### 2. Watermark for Late Data (Not needed for your use case)

**Current:** No watermark

**Why it's fine:**
- Your files arrive in order
- Date prefix ensures ordering
- No need for complex event time handling

**If needed later:**
```python
df.withWatermark("timestamp", "1 hour")
```

#### 3. Backpressure Control (Optional)

**Current:** Processes as fast as manifests arrive

**Optional improvement:**
```python
.trigger(processingTime='30 seconds')  # Current
# OR
.trigger(once=True)  # Process available data then stop
# OR  
.trigger(availableNow=True)  # Process all available, then stop
```

**Why current is good:**
- Continuous processing matches your workload
- 30-second interval is reasonable

#### 4. Metrics and Monitoring (Enhancement)

**Add custom metrics:**
```python
def _write_parquet(self, df: DataFrame, output_path: str) -> int:
    record_count = df.count()
    
    # Add custom metric
    cloudwatch = boto3.client('cloudwatch')
    cloudwatch.put_metric_data(
        Namespace='GlueStreaming',
        MetricData=[{
            'MetricName': 'RecordsProcessed',
            'Value': record_count,
            'Unit': 'Count'
        }]
    )
    
    # Continue with write...
```

## Streaming Job Lifecycle

### 1. Job Start

```bash
aws glue start-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor

# Job State: STARTING → RUNNING
```

**What happens:**
1. Glue allocates 10 G.2X workers (~2 minutes)
2. Spark cluster initializes
3. Checkpoint location validated
4. Streaming query starts
5. Job enters **RUNNING** state

### 2. Normal Operation (24/7)

```
[RUNNING] → Check S3 every 30s → Process batches → Update checkpoint → Repeat
```

**CloudWatch Logs:**
```
[INFO] Initialized processor
[INFO] Starting manifest stream processing
[INFO] Processing manifest batch 0
[INFO] Reading 286 NDJSON files
[INFO] Successfully read 143000 records
[INFO] Writing 143000 records to s3://output/merged-parquet-2025-12-21/
[INFO] Successfully wrote 143000 records
[INFO] Processing manifest batch 1
...
```

### 3. Job Monitoring

**Key metrics to watch:**

```python
# In your Control Plane Lambda
job_run = glue.get_job_run(JobName=job_name, RunId=run_id)

print(f"State: {job_run['JobRunState']}")  # Should be: RUNNING
print(f"Execution Time: {job_run['ExecutionTime']}")  # Increases over time
print(f"DPU Seconds: {job_run['DPUSeconds']}")  # Cost tracking
```

**Normal behavior:**
- State: **RUNNING** (always, until you stop it)
- Execution Time: Increases continuously (24 hours, 48 hours, etc.)
- DPU Seconds: `ExecutionTime × NumberOfWorkers`

### 4. Job Stop (Graceful)

```bash
# Stop the streaming job
aws glue stop-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --job-run-id <JOB_RUN_ID>
```

**What happens:**
1. Current micro-batch completes
2. Checkpoint written
3. Streaming query stops
4. Workers deallocated
5. Job State: **STOPPED**

**Checkpoint preserved** → Can resume later without data loss!

### 5. Job Restart

```bash
aws glue start-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor
```

**What happens:**
1. New workers allocated
2. Reads last checkpoint
3. Resumes from last processed batch
4. Continues processing

**Example:**
```
Before stop: Processed batches 0-100
After restart: Starts from batch 101
No manifests reprocessed! ✓
```

## Failure Scenarios & Recovery

### Scenario 1: Job Crashes (Worker Failure)

**What happens:**
```
Batch 50 processing → Worker dies → Job State: FAILED
```

**Recovery:**
```bash
# Restart job
aws glue start-job-run --job-name <JOB_NAME>

# Checkpoint ensures:
# - Batch 50 not marked complete
# - Will reprocess batch 50
# - No data loss ✓
```

### Scenario 2: Checkpoint Write Failure

**What happens:**
```
Batch processed → Write checkpoint → S3 error → Retry → Success
```

**Built-in retry logic:**
- Spark retries checkpoint writes
- If all retries fail → Micro-batch fails
- Will reprocess from last successful checkpoint

### Scenario 3: S3 Throttling

**What happens:**
```
Reading 286 files → S3 rate limit → Exponential backoff → Eventually succeeds
```

**Spark's built-in handling:**
- Automatic retry with exponential backoff
- Will slow down but won't fail
- Eventually catches up

### Scenario 4: Out of Memory

**What happens:**
```
Processing 1GB → Memory full → GC overhead → Eventually OOM
```

**Solutions:**
1. **Increase worker size:** G.2X → G.4X (32GB → 64GB RAM)
2. **Reduce batch size:** 1GB → 500MB manifests
3. **Increase workers:** 10 → 15 workers
4. **Optimize code:** More aggressive coalescing

## Cost Analysis

### Current Configuration Cost

```
10 Workers × G.2X × $0.44 per DPU-hour

G.2X = 1 DPU
10 workers = 10 DPU
10 DPU × $0.44/hour = $4.40/hour

24/7 operation:
$4.40/hour × 24 hours × 30 days = $3,168/month
```

### Cost Optimization Options

**Option 1: Scale down during off-peak (if applicable)**
```
Peak (8am-8pm): 10 workers = $2.64/day
Off-peak (8pm-8am): 5 workers = $1.32/day
Monthly: ~$2,376 (saves $792/month)
```

**Option 2: Use smaller workers if possible**
```
Current: G.2X (8 vCPU, 32GB) × 10 = $3,168/month
Alternative: G.1X (4 vCPU, 16GB) × 10 = $1,584/month (saves $1,584)

⚠️ But: Slower processing, may not keep up with 200K files/hour
```

**Option 3: Reduce workers if queue stays empty**
```
Monitor queue depth:
- If always <100 manifests queued → Can reduce workers
- If growing queue → Need more workers

Start with 10, adjust based on metrics
```

## Performance Tuning

### Current Performance

**Expected:**
```
1GB batch = 286 files = ~143,000 records
Processing time: 2-5 minutes
Throughput: 12-30 batches/hour = 12-30 GB/hour per job
With continuous stream: ~20 batches/hour average
```

**For 700GB/hour:**
```
700GB ÷ 20 GB/hour = 35 batches/hour
= 1 batch every ~1.7 minutes ✓ (within 2-5 min range)
```

### Optimization Checklist

**If processing is slow:**
- [ ] Increase workers: 10 → 15 or 20
- [ ] Increase worker size: G.2X → G.4X
- [ ] Reduce shuffle partitions: 100 → 50 (less overhead)
- [ ] Increase files per trigger: 1 → 2 (process 2 manifests at once)

**If processing is fast (queue empty):**
- [ ] Reduce workers: 10 → 5 or 7
- [ ] Keep same worker type
- [ ] Save costs!

**Monitor:**
```python
# Check batch processing time
batch_start = time.time()
# ... process batch ...
batch_duration = time.time() - batch_start

if batch_duration > 300:  # 5 minutes
    print("WARNING: Slow batch processing")
```

## Monitoring Dashboard

### Key Metrics

**Job Level:**
```
- Job State (RUNNING/STOPPED/FAILED)
- Execution Time (hours)
- DPU Usage (DPU-hours)
- Cost ($ per hour)
```

**Batch Level:**
```
- Batches processed per hour
- Average batch processing time
- Records processed per batch
- Checkpoint lag (batches behind)
```

**Query:**
```bash
# Get current job status
aws glue get-job-run \
  --job-name ndjson-parquet-sqs-streaming-processor \
  --run-id <JOB_RUN_ID> \
  --query 'JobRun.[JobRunState,ExecutionTime,DPUSeconds]'
```

## Conclusion

### Your Glue Streaming Implementation: ⭐⭐⭐⭐⭐ EXCELLENT!

**Strengths:**
✅ Properly configured for streaming  
✅ Efficient checkpoint usage  
✅ Good error handling  
✅ Optimal Spark configuration  
✅ Correct worker sizing for workload  
✅ Smart coalescing for output  

**Minor Suggestions:**
1. Add checkpoint cleanup (saves S3 costs)
2. Add custom CloudWatch metrics (better visibility)
3. Monitor and adjust workers based on queue depth

**Overall:**
Your Glue streaming job is **production-ready** and follows AWS best practices. The 24/7 streaming approach is **perfect** for your continuous high-volume workload!

### Key Takeaways

1. **Streaming vs Batch:** Streaming is RIGHT for your 200K files/hour use case
2. **Checkpoints:** Critical for exactly-once processing and recovery
3. **Cost:** $3,168/month for 24/7 is reasonable for this throughput
4. **Monitoring:** Watch queue depth and batch processing time
5. **Scaling:** Adjust workers based on actual load

**Your architecture is solid!** 🎉
