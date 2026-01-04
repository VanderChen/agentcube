#!/usr/bin/env python3
"""
PicoD Standalone Test Script

This script tests the PicoD service independently without relying on proposals or test files.
It includes:
1. Multiple rounds of Python code execution
2. File operations (upload, download, list)
3. Command execution
4. Health checks

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
from datetime import datetime, timezone
from typing import Dict, Any, Optional
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.backends import default_backend
import jwt


class PicodClient:
    """Client for interacting with PicoD service"""
    
    def __init__(self, base_url: str, bootstrap_key_path: Optional[str] = None):
        self.base_url = base_url.rstrip('/')
        self.session_private_key = None
        self.session_public_key = None
        self.bootstrap_private_key = None
        self.bootstrap_public_key = None
        self.initialized = False
        
        # Generate session key pair
        self._generate_session_keys()
        
        # Load bootstrap keys if provided
        if bootstrap_key_path:
            self._load_bootstrap_keys(bootstrap_key_path)
    
    def _generate_session_keys(self):
        """Generate RSA key pair for session"""
        print("🔑 Generating session RSA key pair...")
        self.session_private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
            backend=default_backend()
        )
        self.session_public_key = self.session_private_key.public_key()
        print("✅ Session keys generated")
    
    def _load_bootstrap_keys(self, key_path: str):
        """Load bootstrap private key from file"""
        print(f"🔑 Loading bootstrap key from {key_path}...")
        with open(key_path, 'rb') as f:
            self.bootstrap_private_key = serialization.load_pem_private_key(
                f.read(),
                password=None,
                backend=default_backend()
            )
        self.bootstrap_public_key = self.bootstrap_private_key.public_key()
        print("✅ Bootstrap keys loaded")
    
    def _get_public_key_pem(self, public_key) -> str:
        """Convert public key to PEM format and base64 encode (raw, no padding)"""
        pem_bytes = public_key.public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo
        )
        return base64.b64encode(pem_bytes).decode('utf-8').rstrip('=')
    
    def _create_jwt(self, private_key, claims: Dict[str, Any]) -> str:
        """Create JWT token signed with private key"""
        # Add standard claims
        now = datetime.now(timezone.utc)
        claims.update({
            'iat': now,
            'exp': now.timestamp() + 300  # 5 minutes expiry
        })
        
        # Sign with PS256 (RSA-PSS)
        token = jwt.encode(
            claims,
            private_key,
            algorithm='PS256'
        )
        return token
    
    def _build_canonical_request_hash(self, method: str, path: str, body: bytes, 
                                     content_type: Optional[str] = None) -> str:
        """Build canonical request hash for request integrity"""
        # 1. HTTP Method
        method = method.upper()
        
        # 2. URI
        uri = path if path else "/"
        
        # 3. Query String (empty for now)
        query_string = ""
        
        # 4. Canonical Headers
        canonical_headers = ""
        signed_headers = ""
        if content_type:
            canonical_headers = f"content-type:{content_type}\n"
            signed_headers = "content-type"
        else:
            canonical_headers = "\n"
        
        # 5. Body Hash
        body_hash = hashlib.sha256(body).hexdigest()
        
        # Build canonical request
        canonical_request = "\n".join([
            method,
            uri,
            query_string,
            canonical_headers,
            signed_headers,
            body_hash
        ])
        
        # Return SHA256 of canonical request
        return hashlib.sha256(canonical_request.encode()).hexdigest()
    
    def check_initialized(self) -> bool:
        """Check if PicoD is already initialized (static mode)"""
        print("\n🔍 Checking PicoD initialization status...")
        
        try:
            health = self.health_check()
            if health.get('initialized'):
                print("✅ PicoD is already initialized (static mode)")
                # In static mode, we use the session key (which is the same as bootstrap key)
                # The public key is already loaded in PicoD via PICOD_PUBLIC_KEY env var
                self.initialized = True
                # Use session private key for signing (matches the mounted public key)
                self.session_private_key = self.bootstrap_private_key
                self.session_public_key = self.bootstrap_public_key
                return True
            else:
                print("⚠️  PicoD not initialized - dynamic mode requires /init call")
                return False
        except Exception as e:
            print(f"❌ Failed to check initialization: {e}")
            return False
    
    def _make_authenticated_request(self, method: str, path: str, 
                                   json_data: Optional[Dict] = None,
                                   params: Optional[Dict] = None) -> requests.Response:
        """Make authenticated request to PicoD"""
        if not self.initialized:
            raise Exception("PicoD not initialized")
        
        # Prepare body
        body = b''
        content_type = None
        if json_data:
            body = json.dumps(json_data).encode()
            content_type = 'application/json'
        
        # Build canonical request hash
        canonical_hash = self._build_canonical_request_hash(
            method, path, body, content_type
        )
        
        # Create JWT with session key
        token = self._create_jwt(self.session_private_key, {
            'canonical_request_sha256': canonical_hash
        })
        
        headers = {
            'Authorization': f'Bearer {token}'
        }
        if content_type:
            headers['Content-Type'] = content_type
        
        url = f"{self.base_url}{path}"
        
        return requests.request(
            method,
            url,
            headers=headers,
            data=body if body else None,
            params=params,
            timeout=30
        )
    
    def health_check(self) -> Dict[str, Any]:
        """Check PicoD health status"""
        response = requests.get(f"{self.base_url}/health", timeout=5)
        return response.json()
    
    def run_python(self, code: str) -> Dict[str, Any]:
        """Execute Python code"""
        response = self._make_authenticated_request(
            'POST',
            '/api/run_python',
            json_data={'code': code}
        )
        return response.json()
    
    def execute_command(self, command: list, timeout: str = "30s", 
                       working_dir: str = None) -> Dict[str, Any]:
        """Execute shell command"""
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
        """Upload file to PicoD"""
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
        """List files in directory"""
        response = self._make_authenticated_request(
            'GET',
            '/api/files',
            params={'path': path}
        )
        return response.json()
    
    def download_file(self, path: str) -> bytes:
        """Download file from PicoD"""
        response = self._make_authenticated_request(
            'GET',
            f'/api/files/{path}'
        )
        return response.content


def print_section(title: str):
    """Print section header"""
    print(f"\n{'='*70}")
    print(f"  {title}")
    print(f"{'='*70}")


def test_health_check(client: PicodClient):
    """Test health check endpoint"""
    print_section("TEST 1: Health Check")
    
    try:
        health = client.health_check()
        print(f"✅ Health Status: {health.get('status')}")
        print(f"   Service: {health.get('service')}")
        print(f"   Uptime: {health.get('uptime')}")
        print(f"   Initialized: {health.get('initialized')}")
        print(f"   TTL: {health.get('ttl')}s")
        print(f"   Idle: {health.get('idle_seconds')}s")
        return True
    except Exception as e:
        print(f"❌ Health check failed: {e}")
        return False


def test_python_execution(client: PicodClient):
    """Test multiple rounds of Python code execution"""
    print_section("TEST 2: Python Code Execution (Multiple Rounds)")
    
    test_cases = [
        {
            'name': 'Simple arithmetic',
            'code': 'result = 2 + 2\nprint(f"2 + 2 = {result}")'
        },
        {
            'name': 'Variable persistence',
            'code': 'x = 100\ny = 200\nprint(f"x={x}, y={y}")'
        },
        {
            'name': 'Use previous variables',
            'code': 'z = x + y\nprint(f"x + y = {z}")'
        },
        {
            'name': 'List operations',
            'code': 'numbers = [1, 2, 3, 4, 5]\nsquares = [n**2 for n in numbers]\nprint(f"Squares: {squares}")'
        },
        {
            'name': 'Import and use library',
            'code': 'import math\nresult = math.sqrt(16)\nprint(f"sqrt(16) = {result}")'
        },
        {
            'name': 'Define and call function',
            'code': 'def fibonacci(n):\n    if n <= 1:\n        return n\n    return fibonacci(n-1) + fibonacci(n-2)\n\nprint(f"Fibonacci(10) = {fibonacci(10)}")'
        },
        {
            'name': 'Create and manipulate data',
            'code': 'data = {"name": "PicoD", "version": "1.0", "tests": 6}\nprint(f"Data: {data}")\nprint(f"Name: {data[\'name\']}")'
        }
    ]
    
    success_count = 0
    total_time = 0.0
    for i, test in enumerate(test_cases, 1):
        print(f"\n  Round {i}: {test['name']}")
        print(f"  Code: {test['code'][:60]}...")
        
        try:
            start_time = time.time()
            result = client.run_python(test['code'])
            elapsed_time = time.time() - start_time
            total_time += elapsed_time
            
            if result.get('status') == 'ok':
                print(f"  ✅ Status: {result['status']}")
                print(f"     Output: {result.get('output', '').strip()}")
                print(f"     Execution Count: {result.get('execution_count')}")
                print(f"     Server Duration: {result.get('duration'):.3f}s")
                print(f"     Total Time (with network): {elapsed_time:.3f}s")
                success_count += 1
            else:
                print(f"  ❌ Status: {result['status']}")
                print(f"     Error: {result.get('error')}")
                print(f"     Total Time: {elapsed_time:.3f}s")
        except Exception as e:
            print(f"  ❌ Exception: {e}")
    
    print(f"\n  Summary: {success_count}/{len(test_cases)} tests passed")
    print(f"  Total execution time: {total_time:.3f}s")
    print(f"  Average time per test: {total_time/len(test_cases):.3f}s")
    return success_count == len(test_cases)


def test_file_operations(client: PicodClient):
    """Test file upload, list, and download"""
    print_section("TEST 3: File Operations")
    
    try:
        # Test 1: Upload a text file
        print("\n  📤 Uploading text file...")
        text_content = b"Hello from PicoD test!\nThis is a test file.\n"
        upload_result = client.upload_file('test_file.txt', text_content)
        print(f"  ✅ Uploaded: {upload_result.get('path')}")
        print(f"     Size: {upload_result.get('size')} bytes")
        print(f"     Mode: {upload_result.get('mode')}")
        
        # Test 2: Upload a Python script
        print("\n  📤 Uploading Python script...")
        py_content = b"""#!/usr/bin/env python3
def greet(name):
    return f"Hello, {name}!"

if __name__ == "__main__":
    print(greet("PicoD"))
"""
        upload_result = client.upload_file('scripts/hello.py', py_content, mode="755")
        print(f"  ✅ Uploaded: {upload_result.get('path')}")
        
        # Test 3: List files in current directory
        print("\n  📋 Listing files in current directory...")
        files = client.list_files('.')
        print(f"  ✅ Found {len(files.get('files', []))} items:")
        for file in files.get('files', [])[:5]:  # Show first 5
            print(f"     - {file['name']} ({'dir' if file['is_dir'] else 'file'}, {file['size']} bytes)")
        
        # Test 4: Download the uploaded file
        print("\n  📥 Downloading file...")
        downloaded = client.download_file('test_file.txt')
        if downloaded == text_content:
            print(f"  ✅ Downloaded content matches original")
        else:
            print(f"  ❌ Downloaded content mismatch")
            return False
        
        # Test 5: Execute the uploaded Python script
        print("\n  🐍 Executing uploaded Python script...")
        exec_result = client.execute_command(['python3', 'scripts/hello.py'])
        print(f"  ✅ Exit Code: {exec_result.get('exit_code')}")
        print(f"     Output: {exec_result.get('stdout').strip()}")
        
        return True
    except Exception as e:
        print(f"  ❌ File operations failed: {e}")
        return False


def test_command_execution(client: PicodClient):
    """Test command execution"""
    print_section("TEST 4: Command Execution")
    
    commands = [
        {
            'name': 'List directory',
            'cmd': ['ls', '-la']
        },
        {
            'name': 'Print working directory',
            'cmd': ['pwd']
        },
        {
            'name': 'Echo test',
            'cmd': ['echo', 'Hello from PicoD!']
        },
        {
            'name': 'Python version',
            'cmd': ['python3', '--version']
        },
        {
            'name': 'Create and read file',
            'cmd': ['sh', '-c', 'echo "test content" > /tmp/test.txt && cat /tmp/test.txt']
        }
    ]
    
    success_count = 0
    for cmd_test in commands:
        print(f"\n  🔧 {cmd_test['name']}")
        print(f"     Command: {' '.join(cmd_test['cmd'])}")
        
        try:
            result = client.execute_command(cmd_test['cmd'])
            
            if result.get('exit_code') == 0:
                print(f"  ✅ Exit Code: 0")
                output = result.get('stdout', '').strip()
                if output:
                    # Show first 200 chars
                    print(f"     Output: {output[:200]}")
                print(f"     Duration: {result.get('duration'):.3f}s")
                success_count += 1
            else:
                print(f"  ❌ Exit Code: {result.get('exit_code')}")
                print(f"     Stderr: {result.get('stderr')}")
        except Exception as e:
            print(f"  ❌ Exception: {e}")
    
    print(f"\n  Summary: {success_count}/{len(commands)} commands succeeded")
    return success_count == len(commands)


def test_python_with_file_io(client: PicodClient):
    """Test Python code that reads/writes files"""
    print_section("TEST 5: Python with File I/O")
    
    try:
        # Create a data file using Python
        print("\n  📝 Creating data file with Python...")
        code1 = """
import json
data = {
    'test': 'picod',
    'timestamp': '2026-01-04',
    'numbers': [1, 2, 3, 4, 5]
}
with open('data.json', 'w') as f:
    json.dump(data, f, indent=2)
print('Data file created')
"""
        result = client.run_python(code1)
        print(f"  ✅ {result.get('output', '').strip()}")
        
        # Read the file back
        print("\n  📖 Reading data file with Python...")
        code2 = """
import json
with open('data.json', 'r') as f:
    data = json.load(f)
print(f"Loaded data: {data}")
print(f"Numbers sum: {sum(data['numbers'])}")
"""
        result = client.run_python(code2)
        print(f"  ✅ {result.get('output', '').strip()}")
        
        # Verify file exists via file API
        print("\n  🔍 Verifying file via API...")
        downloaded = client.download_file('data.json')
        data = json.loads(downloaded)
        print(f"  ✅ File verified: {data}")
        
        return True
    except Exception as e:
        print(f"  ❌ Python file I/O test failed: {e}")
        return False


def main():
    """Main test runner"""
    print("""
╔══════════════════════════════════════════════════════════════════╗
║                  PicoD Standalone Test Suite                     ║
║                                                                  ║
║  Testing PicoD service independently without proposals           ║
╚══════════════════════════════════════════════════════════════════╝
""")
    
    # Get configuration from environment or use defaults
    picod_url = os.getenv('PICOD_URL', 'http://localhost:8080')
    bootstrap_key = os.getenv('BOOTSTRAP_KEY_PATH', '/tmp/bootstrap_private_key.pem')
    
    print(f"📍 PicoD URL: {picod_url}")
    print(f"🔑 Bootstrap Key: {bootstrap_key}")
    
    # Check if bootstrap key exists
    if not os.path.exists(bootstrap_key):
        print(f"\n⚠️  Bootstrap key not found at {bootstrap_key}")
        print("   Generating temporary bootstrap key pair...")
        
        # Generate bootstrap key pair
        private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
            backend=default_backend()
        )
        
        # Save private key
        with open(bootstrap_key, 'wb') as f:
            f.write(private_key.private_key_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption()
            ))
        
        # Save public key
        public_key_path = bootstrap_key.replace('_private_', '_public_')
        with open(public_key_path, 'wb') as f:
            f.write(private_key.public_key().public_key_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PublicFormat.SubjectPublicKeyInfo
            ))
        
        print(f"   ✅ Generated: {bootstrap_key}")
        print(f"   ✅ Generated: {public_key_path}")
        print(f"\n   ⚠️  NOTE: You need to start PicoD with this public key:")
        print(f"   docker run -p 8080:8080 -v {public_key_path}:/etc/picod/public-key.pem picod")
    
    # Create client
    client = PicodClient(picod_url, bootstrap_key)
    
    # Wait for PicoD to be ready
    print("\n⏳ Waiting for PicoD to be ready...")
    max_retries = 10
    for i in range(max_retries):
        try:
            health = client.health_check()
            print(f"✅ PicoD is ready! Status: {health.get('status')}")
            break
        except Exception as e:
            if i < max_retries - 1:
                print(f"   Retry {i+1}/{max_retries}... ({e})")
                time.sleep(2)
            else:
                print(f"❌ PicoD not accessible after {max_retries} retries")
                print(f"   Error: {e}")
                print(f"\n   Please ensure PicoD is running at {picod_url}")
                sys.exit(1)
    
    # Check if PicoD is initialized (static mode with mounted public key)
    if not client.check_initialized():
        print("\n⚠️  PicoD is not initialized")
        print("   This test script expects PicoD to run in static mode with a mounted public key")
        print("   The public key should match the private key used for signing JWTs")
        sys.exit(1)
    
    # Run tests
    results = []
    
    results.append(('Health Check', test_health_check(client)))
    results.append(('Python Execution', test_python_execution(client)))
    results.append(('File Operations', test_file_operations(client)))
    results.append(('Command Execution', test_command_execution(client)))
    results.append(('Python File I/O', test_python_with_file_io(client)))
    
    # Print summary
    print_section("TEST SUMMARY")
    
    passed = sum(1 for _, result in results if result)
    total = len(results)
    
    for test_name, result in results:
        status = "✅ PASS" if result else "❌ FAIL"
        print(f"  {status}  {test_name}")
    
    print(f"\n  Total: {passed}/{total} tests passed")
    
    if passed == total:
        print("\n🎉 All tests passed!")
        sys.exit(0)
    else:
        print(f"\n⚠️  {total - passed} test(s) failed")
        sys.exit(1)


if __name__ == '__main__':
    main()
