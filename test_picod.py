#!/usr/bin/env python3
"""
PicoD Test Script

This script tests the PicoD service.
It includes:
1. Functional tests (sanity check)
2. Performance/Concurrency tests covering all interfaces
3. Metrics collection to CSV

Requirements:
- PicoD container running and accessible
- Python 3.x with requests library
"""

import os
import sys
import json
import time
import base64
import hashlib
import requests
import concurrent.futures
import threading
import csv
import argparse
import random
from datetime import datetime, timezone
from typing import Dict, Any, Optional
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.backends import default_backend
import jwt


class MetricsCollector:
    def __init__(self, output_file: str, extra_fields: Dict[str, Any]):
        self.output_file = output_file
        self.extra_fields = extra_fields
        self.records = []
        self.lock = threading.Lock()

    def add(self, endpoint: str, method: str, latency: float, status_code: int, error: str = ""):
        with self.lock:
            record = self.extra_fields.copy()
            record.update({
                'timestamp': datetime.now(timezone.utc).isoformat(),
                'endpoint': endpoint,
                'method': method,
                'latency_sec': f"{latency:.6f}",
                'status_code': status_code,
                'error': error
            })
            self.records.append(record)

    def save(self):
        if not self.records:
            return
        
        fieldnames = list(self.extra_fields.keys()) + [
            'timestamp', 'endpoint', 'method', 'latency_sec', 'status_code', 'error'
        ]
        
        file_exists = os.path.isfile(self.output_file)
        
        try:
            with open(self.output_file, 'a', newline='') as f:
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                if not file_exists:
                    writer.writeheader()
                writer.writerows(self.records)
            print(f"  💾 Saved {len(self.records)} metrics to {self.output_file}")
            # Clear records after save to free memory if called periodically
            with self.lock:
                self.records = []
        except Exception as e:
            print(f"  ❌ Failed to save metrics: {e}")


class PicodClient:
    """Client for interacting with PicoD service"""
    
    def __init__(self, base_url: str, bootstrap_key_path: Optional[str] = None, collector: Optional[MetricsCollector] = None):
        self.base_url = base_url.rstrip('/')
        self.session_private_key = None
        self.session_public_key = None
        self.bootstrap_private_key = None
        self.bootstrap_public_key = None
        self.initialized = False
        self.collector = collector
        
        # Generate session key pair
        self._generate_session_keys()
        
        # Load bootstrap keys if provided
        if bootstrap_key_path:
            self._load_bootstrap_keys(bootstrap_key_path)
    
    def _generate_session_keys(self):
        """Generate EC key pair for session"""
        # print("🔑 Generating session EC key pair...")
        self.session_private_key = ec.generate_private_key(
            ec.SECP256R1(),
            backend=default_backend()
        )
        self.session_public_key = self.session_private_key.public_key()
    
    def _load_bootstrap_keys(self, key_path: str):
        """Load bootstrap private key from file"""
        # print(f"🔑 Loading bootstrap key from {key_path}...")
        try:
            with open(key_path, 'rb') as f:
                self.bootstrap_private_key = serialization.load_pem_private_key(
                    f.read(),
                    password=None,
                    backend=default_backend()
                )
            self.bootstrap_public_key = self.bootstrap_private_key.public_key()
        except Exception as e:
            print(f"Error loading bootstrap key: {e}")
            sys.exit(1)
    
    def _create_jwt(self, private_key, claims: Dict[str, Any]) -> str:
        """Create JWT token signed with private key"""
        now = datetime.now(timezone.utc)
        claims.update({
            'iat': now,
            'exp': now.timestamp() + 300
        })
        token = jwt.encode(claims, private_key, algorithm='ES256')
        return token
    
    def _build_canonical_request_hash(self, method: str, path: str, body: bytes, 
                                     content_type: Optional[str] = None) -> str:
        method = method.upper()
        uri = path if path else "/"
        query_string = ""
        
        canonical_headers = ""
        signed_headers = ""
        if content_type:
            canonical_headers = f"content-type:{content_type}\n"
            signed_headers = "content-type"
        else:
            canonical_headers = "\n"
        
        body_hash = hashlib.sha256(body).hexdigest()
        
        canonical_request = "\n".join([
            method,
            uri,
            query_string,
            canonical_headers,
            signed_headers,
            body_hash
        ])
        
        return hashlib.sha256(canonical_request.encode()).hexdigest()
    
    def check_initialized(self) -> bool:
        """Check if PicoD is already initialized (static mode)"""
        try:
            health = self.health_check()
            if health.get('initialized'):
                self.initialized = True
                self.session_private_key = self.bootstrap_private_key
                self.session_public_key = self.bootstrap_public_key
                return True
            return False
        except Exception:
            return False
    
    def _measure_request(self, method, url, **kwargs):
        start_time = time.time()
        status_code = 0
        error_msg = ""
        resp = None
        
        path = url.replace(self.base_url, "")
        
        try:
            resp = requests.request(method, url, **kwargs)
            status_code = resp.status_code
            return resp
        except Exception as e:
            error_msg = str(e)
            raise e
        finally:
            duration = time.time() - start_time
            if self.collector:
                self.collector.add(path, method, duration, status_code, error_msg)

    def _make_authenticated_request(self, method: str, path: str, 
                                   json_data: Optional[Dict] = None,
                                   params: Optional[Dict] = None) -> requests.Response:
        if not self.initialized:
            raise Exception("PicoD not initialized")
        
        body = b''
        content_type = None
        if json_data:
            body = json.dumps(json_data).encode()
            content_type = 'application/json'
        
        canonical_hash = self._build_canonical_request_hash(
            method, path, body, content_type
        )
        
        token = self._create_jwt(self.session_private_key, {
            'canonical_request_sha256': canonical_hash
        })
        
        headers = {
            'Authorization': f'Bearer {token}'
        }
        if content_type:
            headers['Content-Type'] = content_type
        
        url = f"{self.base_url}{path}"
        
        return self._measure_request(
            method,
            url,
            headers=headers,
            data=body if body else None,
            params=params,
            timeout=30
        )
    
    def health_check(self) -> Dict[str, Any]:
        url = f"{self.base_url}/health"
        # Health check is unauthenticated
        resp = self._measure_request('GET', url, timeout=5)
        return resp.json()

    def simple_run_python(self, code: str, timeout: str = "5m") -> Dict[str, Any]:
        response = self._make_authenticated_request(
            'POST',
            '/api/run_python',
            json_data={'code': code, 'timeout': timeout}
        )
        return response.json()

    def run_python_file(self, file_path: str, timeout: str = "5m") -> Dict[str, Any]:
        with open(file_path, 'rb') as f:
            content = f.read()
            
        filename = os.path.basename(file_path)
        boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW'
        
        body_parts = []
        body_parts.append(f'--{boundary}'.encode())
        body_parts.append(f'Content-Disposition: form-data; name="file"; filename="{filename}"'.encode())
        body_parts.append(b'Content-Type: application/octet-stream')
        body_parts.append(b'')
        body_parts.append(content)
        
        body_parts.append(f'--{boundary}'.encode())
        body_parts.append(b'Content-Disposition: form-data; name="timeout"')
        body_parts.append(b'')
        body_parts.append(timeout.encode())
        
        body_parts.append(f'--{boundary}--'.encode())
        body_parts.append(b'')
        
        body = b'\r\n'.join(body_parts)
        
        content_type = f'multipart/form-data; boundary={boundary}'
        
        canonical_hash = self._build_canonical_request_hash(
            'POST', '/api/run_python_file', body, content_type
        )
        
        token = self._create_jwt(self.session_private_key, {
            'canonical_request_sha256': canonical_hash
        })
        
        headers = {
            'Authorization': f'Bearer {token}',
            'Content-Type': content_type
        }
        
        url = f"{self.base_url}/api/run_python_file"
        resp = self._measure_request(
            'POST',
            url,
            headers=headers,
            data=body,
            timeout=30
        )
        return resp.json()
    
    def execute_command(self, command: list, timeout: str = "30s", 
                       working_dir: str = None) -> Dict[str, Any]:
        data = {
            'command': command,
            'timeout': timeout
        }
        if working_dir:
            data['working_dir'] = working_dir
        
        response = self._make_authenticated_request(
            'POST',
            '/api/execute',
            json_data=data
        )
        return response.json()
    
    def upload_file(self, path: str, content: bytes, mode: str = "644") -> Dict[str, Any]:
        content_b64 = base64.b64encode(content).decode()
        response = self._make_authenticated_request(
            'POST',
            '/api/files',
            json_data={
                'path': path,
                'content': content_b64,
                'mode': mode
            }
        )
        return response.json()
    
    def list_files(self, path: str = ".") -> Dict[str, Any]:
        response = self._make_authenticated_request(
            'GET',
            '/api/files',
            params={'path': path}
        )
        return response.json()
    
    def download_file(self, path: str) -> bytes:
        response = self._make_authenticated_request(
            'GET',
            f'/api/files/{path}'
        )
        return response.content

    def set_ttl(self, ttl_seconds: int) -> Dict[str, Any]:
        response = self._make_authenticated_request(
            'PUT',
            '/api/ttl',
            json_data={'ttl': ttl_seconds}
        )
        return response.json()

# --- Test Definitions ---

def run_functional_tests(client: PicodClient):
    print("\n🧪 Running Functional Tests (Single Point)...")
    
    # 1. Health
    print("  Checking Health...", end=" ")
    try:
        client.health_check()
        print("✅")
    except Exception as e:
        print(f"❌ {e}")
        return False

    # 2. Command
    print("  Executing Command...", end=" ")
    try:
        res = client.execute_command(['echo', 'hello'])
        if res.get('exit_code') == 0 and 'hello' in res.get('stdout'):
            print("✅")
        else:
            print(f"❌ {res}")
            return False
    except Exception as e:
        print(f"❌ {e}")
        return False

    # 3. Simple Python
    print("  Running Simple Python...", end=" ")
    try:
        code_b64 = base64.b64encode(b"print('py_test')").decode()
        res = client.simple_run_python(code_b64)
        if 'py_test' in res.get('stdout', ''):
            print("✅")
        else:
            print(f"❌ {res}")
            return False
    except Exception as e:
        print(f"❌ {e}")
        return False

    # 4. TTL
    print("  Setting TTL...", end=" ")
    try:
        # Set to 1 hour
        res = client.set_ttl(3600)
        if res.get('ttl') == 3600:
             # Verify via health
             health = client.health_check()
             if health.get('ttl') == 3600:
                 print("✅")
             else:
                 print(f"❌ Health TTL mismatch: {health.get('ttl')}")
                 return False
        else:
            print(f"❌ {res}")
            return False
    except Exception as e:
        print(f"❌ {e}")
        return False
        
    return True

def run_concurrent_tests(client: PicodClient, concurrency: int, task_name: str, task_func, duration_sec: int = 10):
    print(f"\n🚀 Running Concurrent Test: {task_name} (Concurrency: {concurrency})...")
    
    start_time = time.time()
    count = 0
    errors = 0
    
    # We want to run for a specific duration or specific number of iterations.
    # To properly stress test, let's run fixed N requests per thread or time based.
    # The requirement is "concurrent test every interface".
    # Let's do a fixed number of requests to keep it deterministic for the table.
    # Or better: ensure we have enough samples.
    
    requests_per_thread = max(1, 50 // concurrency) if concurrency > 0 else 1 # Adjust scale
    if concurrency >= 20:
        requests_per_thread = 5 # 20 * 5 = 100 requests total
    elif concurrency >= 10:
        requests_per_thread = 10 # 10 * 10 = 100 requests total
    else:
        requests_per_thread = 20 # 5 * 20 = 100 requests total
        
    total_requests = requests_per_thread * concurrency
    print(f"  Target: {total_requests} requests total ({requests_per_thread} per thread)")

    def worker():
        nonlocal count, errors
        for _ in range(requests_per_thread):
            try:
                task_func(client)
                count += 1
            except Exception as e:
                errors += 1
                # print(f"E: {e}")

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [executor.submit(worker) for _ in range(concurrency)]
        concurrent.futures.wait(futures)

    duration = time.time() - start_time
    print(f"  Done. Success: {count}, Errors: {errors}, Duration: {duration:.2f}s, TPS: {count/duration:.2f}")

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', default='http://localhost:8080')
    parser.add_argument('--key', default='/tmp/bootstrap_private_key.pem')
    parser.add_argument('--concurrency', type=int, default=1)
    parser.add_argument('--cpu-limit', default='unknown')
    parser.add_argument('--output-csv', required=True)
    parser.add_argument('--mode', choices=['functional', 'concurrent', 'all'], default='all')
    args = parser.parse_args()

    # Ensure output directory exists
    os.makedirs(os.path.dirname(os.path.abspath(args.output_csv)), exist_ok=True)

    extra_fields = {
        'concurrency_level': args.concurrency,
        'cpu_limit': args.cpu_limit
    }
    
    collector = MetricsCollector(args.output_csv, extra_fields)
    
    # Setup Client
    if not os.path.exists(args.key):
        # Generate temp key if missing (for standalone local test)
        print(f"⚠️ Key not found: {args.key}, generating temporary...")
        # ... logic omitted for brevity, assuming run_picod_test.sh handles this normally ...
        # But for robustness we should generate:
        priv = ec.generate_private_key(ec.SECP256R1(), default_backend())
        with open(args.key, 'wb') as f:
            f.write(priv.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        # Warning: Public key on server side must match!
        # The shell script ensures this. If running standalone python, this might fail auth if server has different key.
        
    client = PicodClient(args.url, args.key, collector)

    # Wait for readiness
    ready = False
    for _ in range(10):
        try:
            if client.health_check().get('status') == 'ok':
                ready = True
                break
        except:
            time.sleep(1)
    
    if not ready:
        print("❌ Service not ready")
        sys.exit(1)

    if not client.check_initialized():
        print("❌ Service not initialized")
        sys.exit(1)

    # Functional Tests (Single Point)
    if args.mode in ['functional', 'all']:
        if not run_functional_tests(client):
            print("❌ Functional tests failed")
            sys.exit(1)
        # Flush metrics
        collector.save()

    # Concurrent Tests
    if args.mode in ['concurrent', 'all']:
        # Define tasks
        
        # 1. Health
        run_concurrent_tests(client, args.concurrency, "Health Check", 
                           lambda c: c.health_check())
        
        # 2. Command
        run_concurrent_tests(client, args.concurrency, "Execute Command", 
                           lambda c: c.execute_command(['echo', 'test']))
                           
        # 3. Simple Python
        code_b64 = base64.b64encode(b"print(1+1)").decode()
        run_concurrent_tests(client, args.concurrency, "Run Python", 
                           lambda c: c.simple_run_python(code_b64))

        # 4. Upload File
        def task_upload(c):
            c.upload_file(f"test_{random.randint(0,1000)}.txt", b"content")
        run_concurrent_tests(client, args.concurrency, "Upload File", task_upload)

        # 5. List Files
        run_concurrent_tests(client, args.concurrency, "List Files", 
                           lambda c: c.list_files())

        # 6. Download File (setup first)
        client.upload_file("download_test.txt", b"download_me")
        run_concurrent_tests(client, args.concurrency, "Download File", 
                           lambda c: c.download_file("download_test.txt"))
        
        # 7. Run Python File (setup first)
        with open("temp_run.py", "w") as f:
            f.write("print('hello')")
        run_concurrent_tests(client, args.concurrency, "Run Python File", 
                           lambda c: c.run_python_file("temp_run.py"))
        os.remove("temp_run.py")

        collector.save()

if __name__ == '__main__':
    main()