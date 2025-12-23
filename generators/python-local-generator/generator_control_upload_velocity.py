import boto3 
import time

s3 = boto3.client("s3")



FILES_PER_SECOND = 80
INTERVAL = 1 / FILES_PER_SECOND

import json
import os
import time
import random
from datetime import datetime, timezone


TARGET_MB = 3.5
ROWS = 5000

def generate_ndjson(path):
    with open(path, "w") as f:
        for i in range(ROWS):
            record = {
                "id": i,
                "ts": datetime.now(timezone.utc).isoformat(),
                "value": random.random(),
                "payload": "X" * 500   # padding
            }
            f.write(json.dumps(record) + "\n")

    # Pad file to target size
    size_mb = os.path.getsize(path) / (1024 * 1024)
    if size_mb < TARGET_MB:
        with open(path, "a") as f:
            f.write(" " * int((TARGET_MB - size_mb) * 1024 * 1024))

'''
Control upload velocity (this is the key)
This directly simulates:
S3 PUT rate
SQS message rate
Glue ingestion pressure

'''
for i in range(10):
    filename = f"2025-01-01-test-{i}.ndjson"
    generate_ndjson(filename)

    s3.upload_file(filename, "ndjson-input-sqs-804450520964", f"input/{filename}")

    time.sleep(INTERVAL)


