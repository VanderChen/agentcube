#!/bin/bash
# Test script for directory upload/download APIs

set -e

PICOD_URL="${PICOD_URL:-http://localhost:8080}"
PRIVATE_KEY="${PRIVATE_KEY:-/tmp/bootstrap_private_key.pem}"

# Generate JWT token
generate_jwt() {
  python3 << EOF
import jwt
import time
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend

with open('${PRIVATE_KEY}', 'rb') as f:
    private_key = serialization.load_pem_private_key(
        f.read(), password=None, backend=default_backend()
    )

now = int(time.time())
payload = {'exp': now + 300, 'iat': now}
token = jwt.encode(payload, private_key, algorithm='PS256')
print(token)
EOF
}

export JWT_TOKEN=$(generate_jwt)

echo "======================================"
echo "Testing Directory Upload/Download APIs"
echo "======================================"

# Test 1: Upload directory with multiple files
echo ""
echo "Test 1: Upload Directory"
echo "------------------------"

python3 << 'PYEOF'
import requests
import json
import base64
import os

JWT_TOKEN = os.environ['JWT_TOKEN']
PICOD_URL = os.environ['PICOD_URL']

files_data = [
    ("src/main.py", "print('Hello from main.py')\n", "755"),
    ("src/utils.py", "def helper():\n    return 42\n", "644"),
    ("README.md", "# Test Project\nThis is a test.\n", "644"),
    ("data/config.json", '{"debug": true}\n', "644"),
]

files = []
for path, content, mode in files_data:
    files.append({
        "path": path,
        "content": base64.b64encode(content.encode()).decode(),
        "mode": mode
    })

payload = {
    "base_path": "test_project",
    "files": files
}

response = requests.post(
    f"{PICOD_URL}/api/directories",
    headers={
        "Authorization": f"Bearer {JWT_TOKEN}",
        "Content-Type": "application/json"
    },
    json=payload
)

print(f"Status: {response.status_code}")
print(json.dumps(response.json(), indent=2))
PYEOF

# Test 2: Download directory as tar.gz
echo ""
echo "Test 2: Download Directory (tar.gz)"
echo "-----------------------------------"

curl -s -X GET "${PICOD_URL}/api/directories/test_project?format=tar.gz" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o /tmp/test_project.tar.gz

if [ -f /tmp/test_project.tar.gz ]; then
    echo "✅ Downloaded tar.gz successfully"
    echo "Archive contents:"
    tar -tzf /tmp/test_project.tar.gz | head -10

    # Extract and verify
    mkdir -p /tmp/extract_test
    tar -xzf /tmp/test_project.tar.gz -C /tmp/extract_test
    echo ""
    echo "Extracted files:"
    find /tmp/extract_test -type f
    rm -rf /tmp/extract_test /tmp/test_project.tar.gz
else
    echo "❌ Failed to download tar.gz"
    exit 1
fi

# Test 3: Download directory as zip
echo ""
echo "Test 3: Download Directory (zip)"
echo "--------------------------------"

curl -s -X GET "${PICOD_URL}/api/directories/test_project?format=zip" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o /tmp/test_project.zip

if [ -f /tmp/test_project.zip ]; then
    echo "✅ Downloaded zip successfully"
    echo "Archive contents:"
    unzip -l /tmp/test_project.zip | head -15
    rm -f /tmp/test_project.zip
else
    echo "❌ Failed to download zip"
    exit 1
fi

# Test 4: List uploaded files
echo ""
echo "Test 4: Verify Files with List API"
echo "-----------------------------------"

curl -s -X GET "${PICOD_URL}/api/files?path=test_project" \
  -H "Authorization: Bearer ${JWT_TOKEN}" | jq '.'

echo ""
echo "======================================"
echo "All tests completed successfully! ✅"
echo "======================================"
