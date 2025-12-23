import json
from datetime import datetime, timezone

# Generate ~3.5MB of NDJSON data
i = 1  # Define the file number
with open(f'./tmp/test-files/2025-12-21-test{i:04d}.ndjson', 'w') as f:
    for j in range(5000):  # Adjust to get ~3.5MB
        record = {
            'id': f'rec_{i}_{j}',
            'timestamp': datetime.now(timezone.utc).isoformat(),
            'data': 'x' * 700  # Pad to reach target size
        }
        f.write(json.dumps(record) + '\n')