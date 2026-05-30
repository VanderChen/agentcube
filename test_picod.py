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
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
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
    
    def __init__(self, base_url: str, bootstrap_key_path: Optional[str] = None, collector: Optional[MetricsCollector] = None, encryption_enabled: bool = False):
        self.base_url = base_url.rstrip('/')
        self.session_private_key = None
        self.session_public_key = None
        self.bootstrap_private_key = None
        self.bootstrap_public_key = None
        self.initialized = False
        self.collector = collector
        self.encryption_enabled = encryption_enabled
        self.pair1_pub = None # Session Public Key (Pair1)
        
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
            'exp': int(now.timestamp() + 300)
        })
        token = jwt.encode(claims, private_key, algorithm='ES256')
        return token
    
    def _build_canonical_request_hash(self, method: str, url: str, body: bytes,
                                     headers: Optional[Dict[str, str]] = None) -> str:
        from urllib.parse import urlparse, parse_qs, quote
        method = method.upper()

        # Parse URL to extract path and query string
        parsed = urlparse(url)
        # Use quote to ensure path is percent-encoded like Go's EscapedPath()
        # safe='/' because we want to keep slashes
        uri = quote(parsed.path, safe='/') if parsed.path else "/"

        # Build canonical query string (sorted)
        query_string = ""
        if parsed.query:
            params = parse_qs(parsed.query, keep_blank_values=True)
            # Sort and format query parameters
            sorted_params = sorted([(k, v[0] if v else '') for k, vals in params.items() for v in (vals if vals else [''])])
            query_string = '&'.join(f"{k}={v}" for k, v in sorted_params)

        canonical_headers = ""
        signed_headers = ""
        if headers and 'Content-Type' in headers:
            canonical_headers = f"content-type:{headers['Content-Type'].strip()}\n"
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
                # In static mode, session key is bootstrap key
                self.session_private_key = self.bootstrap_private_key
                self.session_public_key = self.bootstrap_public_key
                
                # If encryption is enabled, we need to negotiate Pair1
                if self.encryption_enabled:
                    return self._negotiate_encryption()
                return True
            return False
        except Exception as e:
            print(f"Check initialized failed: {e}")
            return False

    def _negotiate_encryption(self) -> bool:
        """Negotiate Pair1 session key for encryption"""
        print("🔑 Negotiating encryption session key...")
        try:
            # 1. Create JWT signed with bootstrap key
            token = self._create_jwt(self.bootstrap_private_key, {})
            
            # 2. Call /init
            url = f"{self.base_url}/init"
            headers = {'Authorization': f'Bearer {token}'}
            resp = self._measure_request('POST', url, headers=headers, timeout=10)
            resp.raise_for_status()
            
            data = resp.json()
            encrypted_pub1 = base64.b64decode(data['pub1'])
            tmp_pub_bytes = base64.b64decode(data['ephemeral_public_key'])
            nonce = base64.b64decode(data['nonce'])
            
            # 3. Compute shared secret
            # ephemeral_public_key in response is raw bytes from ecdh.PublicKey().Bytes() (for P-256 it's 65 bytes uncompressed or 33 compressed)
            # The server uses tmpPriv.PublicKey().Bytes()
            from cryptography.hazmat.primitives.asymmetric import ec
            tmp_pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), tmp_pub_bytes)
            
            shared_secret = self.bootstrap_private_key.exchange(ec.ECDH(), tmp_pub)
            
            # 4. Derive wrapKey
            hkdf = HKDF(
                algorithm=hashes.SHA256(),
                length=32,
                salt=None,
                info=b"picod-init-wrap",
                backend=default_backend()
            )
            wrap_key = hkdf.derive(shared_secret)
            
            # 5. Decrypt Pub1
            aesgcm = AESGCM(wrap_key)
            pub1_der = aesgcm.decrypt(nonce, encrypted_pub1, None)
            
            # 6. Parse Pub1
            self.pair1_pub = serialization.load_der_public_key(pub1_der, backend=default_backend())
            print("✅ Encryption session key negotiated successfully")
            return True
        except Exception as e:
            print(f"❌ Encryption negotiation failed: {e}")
            import traceback
            traceback.print_exc()
            return False

    def _encrypt_body(self, body: bytes) -> (bytes, str, str):
        """Encrypt request body using Hybrid approach"""
        # 1. Generate ephemeral key pair
        eph_priv = ec.generate_private_key(ec.SECP256R1(), default_backend())
        eph_pub = eph_priv.public_key()
        
        # 2. Compute shared secret with Pair1_Pub
        shared_secret = eph_priv.exchange(ec.ECDH(), self.pair1_pub)
        
        # 3. Derive session key (SK)
        hkdf = HKDF(
            algorithm=hashes.SHA256(),
            length=32,
            salt=None,
            info=b"picod-business-wrap",
            backend=default_backend()
        )
        sk = hkdf.derive(shared_secret)
        
        # 4. AES-GCM Encrypt
        nonce = os.urandom(12)
        aesgcm = AESGCM(sk)
        ciphertext = aesgcm.encrypt(nonce, body, None)
        
        # 5. Return results
        eph_pub_bytes = eph_pub.public_bytes(
            encoding=serialization.Encoding.X962,
            format=serialization.PublicFormat.UncompressedPoint
        )
        return ciphertext, base64.b64encode(eph_pub_bytes).decode(), base64.b64encode(nonce).decode()
    
    def _measure_request(self, method, url, **kwargs):
        start_time = time.time()
        status_code = 0
        error_msg = ""
        resp = None
        
        path = url.replace(self.base_url, "")
        
        try:
            resp = requests.request(method, url, **kwargs)
            status_code = resp.status_code
            
            # If PICOD_FORCE_OCTET_STREAM is enabled, verify Content-Type
            if os.getenv('TEST_FORCE_OCTET') == 'true':
                ct = resp.headers.get('Content-Type', '')
                if ct != 'application/octet-stream':
                    print(f"  ⚠️ Warning: Expected application/octet-stream, got {ct}")
            
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
                                   params: Optional[Dict] = None,
                                   data: Optional[bytes] = None,
                                   content_type: Optional[str] = None) -> requests.Response:
        if not self.initialized:
            raise Exception("PicoD not initialized")

        body = b''
        if json_data:
            body = json.dumps(json_data).encode()
            content_type = content_type or 'application/json'
        elif data:
            body = data
            content_type = content_type or 'application/octet-stream'

        # Build full URL with query parameters for signing
        url = f"{self.base_url}{path}"
        if params:
            from urllib.parse import urlencode
            query_string = urlencode(sorted(params.items()))
            full_url_for_signing = f"{url}?{query_string}"
        else:
            full_url_for_signing = url

        headers = {}
        if content_type:
            headers['Content-Type'] = content_type

        # Perform encryption if enabled
        if self.encryption_enabled and body:
            encrypted_body, eph_pub_b64, nonce_b64 = self._encrypt_body(body)
            body = encrypted_body
            headers['X-Picod-Eph-Pub'] = eph_pub_b64
            headers['X-Picod-Nonce'] = nonce_b64
            # Content-Type for the POST request is still the original one (e.g. application/json)
            # but the actual body is binary.

        canonical_hash = self._build_canonical_request_hash(
            method, full_url_for_signing, body, headers
        )

        token = self._create_jwt(self.session_private_key, {
            'canonical_request_sha256': canonical_hash
        })

        headers['Authorization'] = f'Bearer {token}'

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
        
        resp = self._make_authenticated_request(
            'POST',
            '/api/run_python_file',
            data=body,
            content_type=content_type
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
        # For large files (>10MB), use multipart upload
        if len(content) > 10 * 1024 * 1024:
            return self.upload_file_multipart(path, content, mode)

        # For small files, use JSON base64 upload
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

    def upload_file_multipart(self, path: str, content: bytes, mode: str = "644") -> Dict[str, Any]:
        """Upload file using multipart/form-data (for large files)"""
        if not self.initialized:
            raise Exception("PicoD not initialized")

        # Manually build multipart body with correct format
        import uuid
        boundary = uuid.uuid4().hex

        parts = []

        # Add 'path' field
        parts.append(f'--{boundary}\r\n'.encode())
        parts.append(b'Content-Disposition: form-data; name="path"\r\n\r\n')
        parts.append(path.encode() + b'\r\n')

        # Add 'mode' field
        parts.append(f'--{boundary}\r\n'.encode())
        parts.append(b'Content-Disposition: form-data; name="mode"\r\n\r\n')
        parts.append(mode.encode() + b'\r\n')

        # Add 'file' field
        filename = os.path.basename(path)
        parts.append(f'--{boundary}\r\n'.encode())
        parts.append(f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode())
        parts.append(b'Content-Type: application/octet-stream\r\n\r\n')
        parts.append(content)
        parts.append(b'\r\n')

        # Add closing boundary
        parts.append(f'--{boundary}--\r\n'.encode())

        body = b''.join(parts)
        content_type = f'multipart/form-data; boundary={boundary}'

        resp = self._make_authenticated_request(
            'POST',
            '/api/files',
            data=body,
            content_type=content_type
        )
        return resp.json()
    
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

    # 5. Multi-level Path File Test
    print("  Testing Multi-level Path (a/b/c.txt)...", end=" ")
    try:
        # Create directory structure using execute command
        client.execute_command(['mkdir', '-p', 'a/b'])

        # Upload file to a/b/c.txt
        test_content = b"test content in nested path"
        client.upload_file('a/b/c.txt', test_content)

        # Download and verify
        downloaded = client.download_file('a/b/c.txt')
        if downloaded == test_content:
            print("✅")
        else:
            print(f"❌ Content mismatch")
            return False
    except Exception as e:
        print(f"❌ {e}")
        return False

    # 6. 32MB File Test (actually 31.5MB to account for multipart overhead)
    print("  Testing 31.5MB File Upload/Download...", end=" ")
    try:
        # Generate 31.5MB file (leaves room for multipart overhead under 32MB limit)
        large_content = os.urandom(int(31.5 * 1024 * 1024))
        client.upload_file('large_file_31_5mb.bin', large_content)

        # Download and verify
        downloaded = client.download_file('large_file_31_5mb.bin')
        if downloaded == large_content:
            print("✅")
        else:
            print(f"❌ Content mismatch (size: {len(downloaded)} vs {len(large_content)})")
            return False
    except Exception as e:
        print(f"❌ {e}")
        return False

    # 7. Chinese Filename Test
    print("  Testing Chinese Filename (测试文件.txt)...", end=" ")
    try:
        # Upload file with Chinese name
        chinese_content = "这是一个中文测试文件。\nThis is a Chinese test file.".encode('utf-8')
        client.upload_file('测试文件.txt', chinese_content)

        # List files to verify it exists
        response = client.list_files('.')
        files = response.get('files', [])
        file_names = [f['name'] for f in files]
        if '测试文件.txt' not in file_names:
            print(f"❌ Chinese file not found in list")
            return False

        # Download and verify
        downloaded = client.download_file('测试文件.txt')
        if downloaded == chinese_content:
            print("✅")
        else:
            print(f"❌ Content mismatch")
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
    parser.add_argument('--encryption', action='store_true', help='Enable request encryption')
    args = parser.parse_args()

    # Ensure output directory exists
    os.makedirs(os.path.dirname(os.path.abspath(args.output_csv)), exist_ok=True)

    extra_fields = {
        'concurrency_level': args.concurrency,
        'cpu_limit': args.cpu_limit,
        'encryption': args.encryption
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
        
    client = PicodClient(args.url, args.key, collector, encryption_enabled=args.encryption)

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