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

    def simple_run_python(self, code: str, timeout: str = "5m") -> Dict[str, Any]:
        """Execute Python code using simple runner"""
        response = self._make_authenticated_request(
            'POST',
            '/api/run_python',
            json_data={'code': code, 'timeout': timeout}
        )
        return response.json()

    def run_python_file(self, file_path: str, timeout: str = "5m") -> Dict[str, Any]:
        """Execute Python code via file upload"""
        with open(file_path, 'rb') as f:
            content = f.read()
            
        filename = os.path.basename(file_path)
        boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW'
        
        # Build multipart body manually
        body_parts = []
        body_parts.append(f'--{boundary}'.encode())
        body_parts.append(f'Content-Disposition: form-data; name="file"; filename="{filename}"'.encode())
        body_parts.append(b'Content-Type: application/octet-stream')
        body_parts.append(b'')
        body_parts.append(content)
        
        # Add timeout field
        body_parts.append(f'--{boundary}'.encode())
        body_parts.append(b'Content-Disposition: form-data; name="timeout"')
        body_parts.append(b'')
        body_parts.append(timeout.encode())
        
        body_parts.append(f'--{boundary}--'.encode())
        body_parts.append(b'')
        
        body = b'\r\n'.join(body_parts)
        
        content_type = f'multipart/form-data; boundary={boundary}'
        
        # Build canonical request hash
        canonical_hash = self._build_canonical_request_hash(
            'POST', '/api/run_python_file', body, content_type
        )
        
        # Create JWT with session key
        token = self._create_jwt(self.session_private_key, {
            'canonical_request_sha256': canonical_hash
        })
        
        headers = {
            'Authorization': f'Bearer {token}',
            'Content-Type': content_type
        }
        
        response = requests.post(
            f"{self.base_url}/api/run_python_file",
            headers=headers,
            data=body,
            timeout=30
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

def test_run_python_file(client: PicodClient):
    """Test Python execution via file upload using preset test files"""
    print_section("TEST 5: Python File Execution")

    test_files_dir = "test_files/python"

    # Test 1: Simple hello world
    try:
        print("\n  📝 Test 1: Hello World")
        hello_file = os.path.join(test_files_dir, "hello.py")
        if not os.path.exists(hello_file):
            print(f"  ⚠️  Test file not found: {hello_file}")
            return False

        result = client.run_python_file(hello_file)

        if result.get('exit_code') != 0:
            print(f"  ❌ Exit Code: {result.get('exit_code')}")
            print(f"     Stderr: {result.get('stderr')}")
            return False

        if "Hello from uploaded file" not in result.get('stdout'):
            print(f"  ❌ Output mismatch")
            print(f"     Expected: 'Hello from uploaded file'")
            print(f"     Got: {result.get('stdout')}")
            return False

        print(f"  ✅ Hello world test passed")
        print(f"     Stdout: {result.get('stdout').strip()}")

    except Exception as e:
        print(f"  ❌ Exception in hello world test: {e}")
        return False

    # Test 2: Math operations
    try:
        print("\n  🔢 Test 2: Math Operations")
        math_file = os.path.join(test_files_dir, "math_operations.py")
        if not os.path.exists(math_file):
            print(f"  ⚠️  Test file not found: {math_file}")
            return False

        result = client.run_python_file(math_file)

        if result.get('exit_code') != 0:
            print(f"  ❌ Exit Code: {result.get('exit_code')}")
            print(f"     Stderr: {result.get('stderr')}")
            return False

        if "All math operations passed!" not in result.get('stdout'):
            print(f"  ❌ Math operations failed")
            print(f"     Stdout: {result.get('stdout')}")
            return False

        print(f"  ✅ Math operations test passed")

    except Exception as e:
        print(f"  ❌ Exception in math operations test: {e}")
        return False

    # Test 3: JSON processing
    try:
        print("\n  📦 Test 3: JSON Processing")
        json_file = os.path.join(test_files_dir, "json_processing.py")
        if not os.path.exists(json_file):
            print(f"  ⚠️  Test file not found: {json_file}")
            return False

        result = client.run_python_file(json_file)

        if result.get('exit_code') != 0:
            print(f"  ❌ Exit Code: {result.get('exit_code')}")
            print(f"     Stderr: {result.get('stderr')}")
            return False

        if "JSON processing test passed!" not in result.get('stdout'):
            print(f"  ❌ JSON processing failed")
            return False

        print(f"  ✅ JSON processing test passed")

    except Exception as e:
        print(f"  ❌ Exception in JSON processing test: {e}")
        return False

    # Test 4: Error handling (expect non-zero exit code)
    try:
        print("\n  ⚠️  Test 4: Error Handling")
        error_file = os.path.join(test_files_dir, "error_test.py")
        if not os.path.exists(error_file):
            print(f"  ⚠️  Test file not found: {error_file}")
            return False

        result = client.run_python_file(error_file)

        # This test should fail with exit code 42
        if result.get('exit_code') != 42:
            print(f"  ❌ Expected exit code 42, got {result.get('exit_code')}")
            return False

        if "Error message on stderr" not in result.get('stderr'):
            print(f"  ❌ Expected error message in stderr")
            print(f"     Stderr: {result.get('stderr')}")
            return False

        print(f"  ✅ Error handling test passed (exit code: {result.get('exit_code')})")
        print(f"     Stderr: {result.get('stderr').strip()}")

    except Exception as e:
        print(f"  ❌ Exception in error handling test: {e}")
        return False

    # Test 5: Timeout test
    try:
        print("\n  ⏱️  Test 5: Timeout Handling")
        timeout_file = os.path.join(test_files_dir, "timeout_test.py")
        if not os.path.exists(timeout_file):
            print(f"  ⚠️  Test file not found: {timeout_file}")
            return False

        # Set timeout to 2 seconds (script takes 10 seconds)
        result = client.run_python_file(timeout_file, timeout="2s")

        # Should timeout with exit code 124
        if result.get('exit_code') != 124:
            print(f"  ❌ Expected timeout exit code 124, got {result.get('exit_code')}")
            return False

        if "timed out" not in result.get('stderr').lower():
            print(f"  ⚠️  Expected timeout message in stderr")
            print(f"     Stderr: {result.get('stderr')}")
            # Don't fail the test, as timeout might be reported differently

        print(f"  ✅ Timeout test passed (exit code: {result.get('exit_code')})")

    except Exception as e:
        print(f"  ❌ Exception in timeout test: {e}")
        return False

    print("\n  ✅ All Python file execution tests passed!")
    return True


def test_special_chars_execution(client: PicodClient):
    """Test special characters execution"""
    print_section("TEST 7: Special Characters Execution")
    
    code_samples = [
        ("print('Single Quotes')", "Single Quotes"),
        ('print("Double Quotes")', "Double Quotes"),
        ('print("Mixed \'Single\' in Double")', "Mixed 'Single' in Double"),
        ("print('Mixed \"Double\" in Single')", 'Mixed "Double" in Single'),
        ('print("Line 1\\nLine 2")', "Line 1\nLine 2"),
        ('print("""Multi\nLine\nString""")', "Multi\nLine\nString"),
        ('print("Tab\\tSeparated")', "Tab\tSeparated"),
        ('import sys; print(sys.version.split()[0])', None),
        ('''
s="{\"key\": \"value\"}"
print(s)
'''.strip(), '{"key": "value"}'),
        ('''
def complex_print():
    s1 = "Line 1 with 'single' quotes"
    s2 = 'Line 2 with "double" quotes'
    s3 = """Multiline
    string
    with "quotes" and 'quotes'"""
    return s1 + "\\n" + s2 + "\\n" + s3
print(complex_print())
'''.strip(), "Line 1 with 'single' quotes\nLine 2 with \"double\" quotes\nMultiline\n    string\n    with \"quotes\" and 'quotes'")
    ]
    
    for code, expected_output in code_samples:
        print(f"  Testing code: {code[:40].replace(chr(10), ' ')}...")
        encoded = base64.b64encode(code.encode()).decode()
        result = client.simple_run_python(encoded)
        if result.get('exit_code') != 0:
             print(f"  ❌ Failed. Exit: {result.get('exit_code')}, Stderr: {result.get('stderr')}")
             return False
        
        output = result.get('stdout').strip()
        if expected_output and output != expected_output:
             print(f"  ❌ Output Mismatch. Expected: {repr(expected_output)}, Got: {repr(output)}")
             return False
        print("  ✅ Pass")
        
    return True


def test_simple_python_execution(client: PicodClient):
    """Test simple python execution"""
    print_section("TEST 6: Simple Python Execution")
    
    code = """
import sys
import time
import math
import json

def is_prime(n):
    if n <= 1: return False
    if n <= 3: return True
    if n % 2 == 0 or n % 3 == 0: return False
    i = 5
    while i * i <= n:
        if n % i == 0 or n % (i + 2) == 0: return False
        i += 6
    return True

def fibonacci(n):
    if n <= 0: return []
    if n == 1: return [0]
    sequence = [0, 1]
    while len(sequence) < n:
        sequence.append(sequence[-1] + sequence[-2])
    return sequence

class DataProcessor:
    def __init__(self, data):
        self.data = data
    def process(self):
        return [x*2 for x in self.data]

def calculate_stats(numbers):
    if not numbers:
        return {"min": 0, "max": 0, "avg": 0}
    return {
        "min": min(numbers),
        "max": max(numbers),
        "avg": sum(numbers) / len(numbers)
    }

def main():
    start_time = time.time()
    primes = [x for x in range(100) if is_prime(x)]
    fib = fibonacci(15)
    
    processor = DataProcessor(fib)
    processed_fib = processor.process()
    
    stats = calculate_stats(processed_fib)
    
    # Extra calculations
    matrix = []
    for i in range(5):
        row = []
        for j in range(5):
            row.append((i+1)*(j+1))
        matrix.append(row)
        
    flattened = [val for sublist in matrix for val in sublist]
    matrix_sum = sum(flattened)
    
    result = {
        'primes_count': len(primes),
        'fib_stats': stats,
        'matrix_sum': matrix_sum,
        'python_version': sys.version.split()[0],
        'duration': time.time() - start_time
    }
    
    print(json.dumps(result))

if __name__ == '__main__':
    main()
"""
    
    encoded_code = base64.b64encode(code.encode('utf-8')).decode('utf-8')
    
    try:
        print("  Running complex code...")
        result = client.simple_run_python(encoded_code)
        
        if result.get('exit_code') == 0:
             print(f"  ✅ Exit Code: 0")
             # Try to parse output as JSON
             try:
                 output = json.loads(result.get('stdout'))
                 print(f"     Output: {output}")
             except:
                 print(f"     Stdout: {result.get('stdout')[:100]}...")
             return True
        else:
             print(f"  ❌ Exit Code: {result.get('exit_code')}")
             print(f"     Stderr: {result.get('stderr')}")
             return False
    except Exception as e:
        print(f"  ❌ Exception: {e}")
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
    results.append(('File Operations', test_file_operations(client)))
    results.append(('Command Execution', test_command_execution(client)))
    results.append(('Python File Execution', test_run_python_file(client)))
    results.append(('Simple Python Execution', test_simple_python_execution(client)))
    results.append(('Special Characters Execution', test_special_chars_execution(client)))
    
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
