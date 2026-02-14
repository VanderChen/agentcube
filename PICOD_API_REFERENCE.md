# PicoD API 参考文档 (Static Auth Mode)

本文档详细说明 PicoD 所有 API 接口的使用方法，专注于 **Static Auth Mode (静态认证模式)**。

## 目录

- [概述](#概述)
- [认证机制](#认证机制)
- [环境配置](#环境配置)
- [API 接口](#api-接口)
  - [1. 健康检查](#1-健康检查)
  - [2. 初始化接口 (Static模式不适用)](#2-初始化接口-static模式不适用)
  - [3. 执行Shell命令](#3-执行shell命令)
  - [4. 上传文件](#4-上传文件)
  - [5. 下载文件](#5-下载文件)
  - [6. 列出文件](#6-列出文件)
  - [7. 上传文件夹](#7-上传文件夹)
  - [8. 下载文件夹](#8-下载文件夹)
  - [9. 执行Python代码](#9-执行python代码)
  - [10. 执行Python文件](#10-执行python文件)
  - [11. 设置TTL](#11-设置ttl)
- [测试示例](#测试示例)
- [常见问题](#常见问题)

---

## 概述

PicoD 是一个安全的代码执行环境服务，支持：

- Python 代码执行（基于 Jupyter Kernel）
- Shell 命令执行
- 文件上传、下载、列表
- 文件夹批量上传、打包下载
- TTL（生存时间）管理
- 基于 RSA-PSS JWT 的强认证机制

### 特性说明

- **文件大小限制**: 支持最大 64MB 的文件上传
- **路径支持**: 完整支持多级路径（如 `a/b/c.txt`）
- **中文支持**: 完整支持中文文件名和路径
- **会话持久化**: Python 执行保持会话状态，变量在多次调用间持久化
- **批量操作**: 支持文件夹批量上传和打包下载（tar.gz/zip）

---

## 认证机制

### Static Auth Mode

在静态认证模式下：

1. **服务器启动配置**:
   - 设置环境变量 `PICOD_AUTH_MODE=static`
   - 设置环境变量 `PICOD_PUBLIC_KEY`（base64 编码的 RSA 公钥 PEM）

2. **客户端认证**:
   - 客户端使用对应的私钥签名 JWT
   - 每个 API 请求携带 `Authorization: Bearer <JWT>` 头
   - **不需要**调用 `/init` 接口

3. **JWT 要求**:
   - 签名算法: `PS256` (RSA-PSS with SHA-256)
   - 必需声明: `exp` (过期时间), `iat` (签发时间)
   - 可选声明: `canonical_request_sha256` (请求完整性校验)

### JWT Canonical Request Hash (可选但推荐)

为了防止请求被篡改，建议在 JWT 中包含 `canonical_request_sha256` 声明，计算方法：

```
canonical_request = METHOD + "\n" +
                   URI + "\n" +
                   CANONICAL_QUERY_STRING + "\n" +
                   CANONICAL_HEADERS + "\n" +
                   SIGNED_HEADERS + "\n" +
                   BODY_SHA256

canonical_request_sha256 = hex(sha256(canonical_request))
```

详细规则：
- `METHOD`: HTTP 方法（大写），如 `POST`, `GET`
- `URI`: 请求路径，如 `/api/execute`
- `CANONICAL_QUERY_STRING`: 排序后的查询参数，如 `key1=value1&key2=value2`（按 key 字母序）
- `CANONICAL_HEADERS`: 排序后的 HTTP 头，格式为 `key1:value1\nkey2:value2\n`（按 key 字母序，全小写，去除多余空格）
- `SIGNED_HEADERS`: 包含在签名中的头列表，如 `content-type;host`（按字母序，分号分隔）
- `BODY_SHA256`: 请求体的 SHA256 哈希（十六进制）

---

## 环境配置

### 服务器启动

```bash
# 1. 生成 RSA 密钥对
openssl genrsa -out private_key.pem 2048
openssl rsa -in private_key.pem -pubout -out public_key.pem

# 2. Base64 编码公钥
export PICOD_PUBLIC_KEY=$(cat public_key.pem | base64 -w 0)

# 3. 启动 PicoD 容器
docker run -d --name picod \
  -p 8080:8080 \
  -e PICOD_AUTH_MODE=static \
  -e PICOD_PUBLIC_KEY="${PICOD_PUBLIC_KEY}" \
  -e PICOD_DEFAULT_TTL=3600 \
  picod:latest
```

### 客户端准备

准备 Python 脚本使用私钥生成 JWT：

```python
#!/usr/bin/env python3
import jwt
import time
import hashlib
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend

# 加载私钥
with open('private_key.pem', 'rb') as f:
    private_key = serialization.load_pem_private_key(
        f.read(),
        password=None,
        backend=default_backend()
    )

def generate_jwt(method, uri, body='', headers=None):
    """生成包含 canonical_request_sha256 的 JWT"""
    now = int(time.time())

    # 计算 canonical request hash
    body_sha256 = hashlib.sha256(body.encode() if isinstance(body, str) else body).hexdigest()

    # 构建 canonical request (简化版，完整版需要处理headers)
    canonical_request = f"{method}\n{uri}\n\n\n\n{body_sha256}"
    canonical_hash = hashlib.sha256(canonical_request.encode()).hexdigest()

    # 构建 JWT payload
    payload = {
        'exp': now + 300,  # 5分钟后过期
        'iat': now,
        'canonical_request_sha256': canonical_hash
    }

    # 使用 PS256 签名
    token = jwt.encode(payload, private_key, algorithm='PS256')
    return token

# 示例：生成不包含 canonical_request_sha256 的简单 JWT（用于测试）
def generate_simple_jwt():
    """生成简单 JWT（不验证请求完整性）"""
    now = int(time.time())
    payload = {
        'exp': now + 300,
        'iat': now
    }
    return jwt.encode(payload, private_key, algorithm='PS256')

# 测试用
token = generate_simple_jwt()
print(f"Authorization: Bearer {token}")
```

---

## API 接口

### 1. 健康检查

**描述**: 检查 PicoD 服务健康状态，不需要认证。

**请求**:
```
GET /health
```

**响应**:
```json
{
  "status": "ok",
  "service": "PicoD",
  "uptime": "1h30m45s",
  "initialized": true,
  "last_activity_at": "2026-02-11T10:30:45Z",
  "idle_seconds": 15,
  "ttl": 3600,
  "remaining_seconds": 3585
}
```

**字段说明**:
- `status`: 服务状态，可能值：
  - `ok`: 正常运行
  - `idle`: 空闲超过5分钟
  - `expiring`: 剩余时间少于2分钟
  - `expired`: 已过期（返回 503）
- `service`: 服务名称，固定为 "PicoD"
- `uptime`: 服务运行时间
- `initialized`: 是否已初始化（Static 模式下为 true）
- `last_activity_at`: 最后活动时间（RFC3339 格式）
- `idle_seconds`: 空闲秒数
- `ttl`: 配置的 TTL（秒）
- `remaining_seconds`: 剩余秒数（可能为负数）

**curl 示例**:
```bash
curl -X GET http://localhost:8080/health
```

---

### 2. 初始化接口 (Static模式不适用)

**描述**: 在 Static Auth Mode 下，`/init` 接口被禁用，调用将返回 403 错误。

**请求**:
```
POST /init
```

**响应**:
```json
{
  "error": "Static key mode enabled",
  "code": 403,
  "detail": "Dynamic initialization is disabled in static key mode"
}
```

---

### 3. 执行Shell命令

**描述**: 在沙箱环境中执行 Shell 命令。

**请求**:
```
POST /api/execute
Authorization: Bearer <JWT>
Content-Type: application/json

{
  "command": "ls -la"
}
```

**参数**:
- `command` (string, 必需): 要执行的 Shell 命令

**响应**:
```json
{
  "stdout": "total 16\ndrwxr-xr-x 2 user user 4096 Feb 11 10:30 .\n...",
  "stderr": "",
  "exit_code": 0,
  "execution_time": "0.023s"
}
```

**字段说明**:
- `stdout`: 标准输出
- `stderr`: 标准错误输出
- `exit_code`: 退出码（0 表示成功）
- `execution_time`: 执行时间

**curl 示例**:
```bash
# 需要先生成 JWT token（参考环境配置章节）
export JWT_TOKEN="eyJhbGc..."

# 执行简单命令
curl -X POST http://localhost:8080/api/execute \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "command": "echo Hello PicoD"
  }'

# 执行复杂命令
curl -X POST http://localhost:8080/api/execute \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "command": "pwd && ls -la && python3 --version"
  }'

# 创建文件
curl -X POST http://localhost:8080/api/execute \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "command": "echo \"Hello from shell\" > test.txt && cat test.txt"
  }'
```

---

### 4. 上传文件

**描述**: 上传文件到 PicoD 工作目录，支持多级路径和中文文件名。

#### 方式 1: JSON + Base64 编码

**请求**:
```
POST /api/files
Authorization: Bearer <JWT>
Content-Type: application/json

{
  "path": "subdir/test.txt",
  "content": "SGVsbG8gV29ybGQ=",
  "mode": "644"
}
```

**参数**:
- `path` (string, 必需): 文件路径（相对于工作目录）
  - 支持多级路径，如 `a/b/c/file.txt`
  - 支持中文路径和文件名，如 `测试/文件.txt`
- `content` (string, 必需): Base64 编码的文件内容
- `mode` (string, 可选): 文件权限（八进制字符串），默认 `644`
  - 示例: `"644"` (rw-r--r--), `"755"` (rwxr-xr-x)

**响应**:
```json
{
  "path": "subdir/test.txt",
  "size": 11,
  "mode": "-rw-r--r--",
  "modified": "2026-02-11T10:35:20Z"
}
```

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# 上传简单文本文件
curl -X POST http://localhost:8080/api/files \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "hello.txt",
    "content": "SGVsbG8gUGljb0Qh",
    "mode": "644"
  }'

# 上传到多级目录
curl -X POST http://localhost:8080/api/files \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"path\": \"data/logs/app.log\",
    \"content\": \"$(echo 'Log entry 1' | base64)\",
    \"mode\": \"644\"
  }"

# 上传中文文件名
curl -X POST http://localhost:8080/api/files \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"path\": \"测试文件.txt\",
    \"content\": \"$(echo '这是中文内容' | base64)\",
    \"mode\": \"644\"
  }"

# 上传 Python 脚本
cat > script.py << 'EOF'
def hello():
    print("Hello from Python!")
    return 42

result = hello()
print(f"Result: {result}")
EOF

curl -X POST http://localhost:8080/api/files \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"path\": \"scripts/hello.py\",
    \"content\": \"$(cat script.py | base64 -w 0)\",
    \"mode\": \"755\"
  }"
```

#### 方式 2: Multipart Form Data

**请求**:
```
POST /api/files
Authorization: Bearer <JWT>
Content-Type: multipart/form-data

path=subdir/test.txt
mode=644
file=<binary file data>
```

**参数**:
- `path` (form field, 必需): 文件路径
- `mode` (form field, 可选): 文件权限，默认 `644`
- `file` (file field, 必需): 文件内容

**响应**: 同方式 1

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# 上传本地文件
curl -X POST http://localhost:8080/api/files \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -F "path=uploads/image.png" \
  -F "mode=644" \
  -F "file=@/path/to/local/image.png"

# 上传大文件（最大 64MB）
curl -X POST http://localhost:8080/api/files \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -F "path=data/large_file.zip" \
  -F "mode=644" \
  -F "file=@/path/to/50MB_file.zip"

# 上传到多级中文路径
curl -X POST http://localhost:8080/api/files \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -F "path=数据/图片/测试.jpg" \
  -F "file=@test.jpg"
```

#### 方式 3: 多级路径文件上传（完整示例）

**描述**: 演示创建多级目录并上传文件到嵌套路径。

**步骤**:
1. 创建多级目录结构
2. 上传文件到嵌套路径
3. 验证文件是否上传成功

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# Step 1: 创建多级目录 a/b/c
curl -X POST http://localhost:8080/api/execute \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"command": ["mkdir", "-p", "a/b/c"]}'

# Step 2: 上传文件到 a/b/c/test.txt (JSON 方式)
curl -X POST http://localhost:8080/api/files \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"path\": \"a/b/c/test.txt\",
    \"content\": \"$(echo 'Content in nested path a/b/c' | base64)\",
    \"mode\": \"644\"
  }"

# Step 3: 验证文件 - 列出目录内容
curl -X GET "http://localhost:8080/api/files?path=a/b/c" \
  -H "Authorization: Bearer ${JWT_TOKEN}"

# Step 4: 读取文件内容验证
curl -X POST http://localhost:8080/api/execute \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"command": ["cat", "a/b/c/test.txt"]}'
```

#### 方式 4: 大文件上传（31MB+ 文件，推荐使用 Multipart）

**描述**: 上传大文件（接近 32MB 限制）时推荐使用 multipart 方式，JSON base64 方式会因编码膨胀导致超限。

**限制说明**:
- JSON + Base64: 约 48MB 编码后文件 → 实际支持约 24MB 原始文件
- Multipart: 支持接近 32MB 原始文件（预留 multipart 头部开销）

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# 生成 31MB 测试文件（为 multipart 头部预留 1MB 空间）
dd if=/dev/urandom of=large_file_31mb.bin bs=1M count=31

# 使用 multipart 上传大文件
curl -X POST http://localhost:8080/api/files \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -F "path=uploads/large_file_31mb.bin" \
  -F "mode=644" \
  -F "file=@large_file_31mb.bin"

# 验证文件大小
curl -X POST http://localhost:8080/api/execute \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"command": ["ls", "-lh", "uploads/large_file_31mb.bin"]}'

# 验证文件完整性（使用 md5sum）
md5sum large_file_31mb.bin  # 本地计算 MD5
curl -X POST http://localhost:8080/api/execute \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"command": ["md5sum", "uploads/large_file_31mb.bin"]}'
```

**注意事项**:
- 大文件上传建议设置更长的超时时间（curl 默认无超时）
- 如果上传失败，检查 Docker 容器的内存限制
- 对于更大的文件（>32MB），考虑分块上传或使用文件夹批量上传

---

### 5. 下载文件

**描述**: 从 PicoD 工作目录下载文件，完整支持多级路径和中文文件名。

**请求**:
```
GET /api/files/{path}
Authorization: Bearer <JWT>
```

**参数**:
- `{path}`: URL 路径参数，文件路径（需要 URL 编码）
  - 多级路径: `a/b/c.txt` → URL 编码为 `a/b/c.txt` 或 `a%2Fb%2Fc.txt`
  - 中文文件名: `测试.txt` → URL 编码为 `%E6%B5%8B%E8%AF%95.txt`

**响应**:
- 成功: 返回文件内容（二进制流）
- 失败: 返回 JSON 错误信息

**响应头**:
```
Content-Type: application/octet-stream (或根据文件扩展名自动检测)
Content-Disposition: attachment; filename="file.txt"; filename*=UTF-8''encoded_name.txt
Content-Description: File Transfer
Content-Transfer-Encoding: binary
```

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# 下载简单文件
curl -X GET "http://localhost:8080/api/files/hello.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o downloaded_hello.txt

# 下载多级路径文件
curl -X GET "http://localhost:8080/api/files/data/logs/app.log" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o app.log

# 下载中文文件名（需要 URL 编码）
curl -X GET "http://localhost:8080/api/files/%E6%B5%8B%E8%AF%95%E6%96%87%E4%BB%B6.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o 测试文件.txt

# 使用 --path-as-is 选项处理特殊路径
curl --path-as-is -X GET "http://localhost:8080/api/files/a/b/c/test.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o test.txt

# 下载并查看文本文件内容
curl -X GET "http://localhost:8080/api/files/scripts/hello.py" \
  -H "Authorization: Bearer ${JWT_TOKEN}"
```

### 高级示例：多路径和大文件下载

#### 示例 1: 下载多级嵌套路径文件（完整流程）

```bash
export JWT_TOKEN="eyJhbGc..."

# 假设已经上传了 a/b/c/test.txt 文件
# 下载多级路径文件
curl -X GET "http://localhost:8080/api/files/a/b/c/test.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o downloaded_test.txt

# 或者使用 --path-as-is 避免路径归一化问题
curl --path-as-is -X GET "http://localhost:8080/api/files/a/b/c/test.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o downloaded_test.txt

# 验证文件内容
cat downloaded_test.txt
```

#### 示例 2: 下载大文件（31MB+）并验证完整性

```bash
export JWT_TOKEN="eyJhbGc..."

# 下载大文件（31MB）
curl -X GET "http://localhost:8080/api/files/uploads/large_file_31mb.bin" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o downloaded_large_file.bin \
  --max-time 300  # 设置 5 分钟超时

# 验证文件大小
ls -lh downloaded_large_file.bin

# 计算并比对 MD5（需要先获取服务器端 MD5）
# 获取服务器端 MD5
SERVER_MD5=$(curl -X POST http://localhost:8080/api/execute \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"command": ["md5sum", "uploads/large_file_31mb.bin"]}' | jq -r '.stdout' | awk '{print $1}')

# 计算本地 MD5
LOCAL_MD5=$(md5sum downloaded_large_file.bin | awk '{print $1}')

# 比对
if [ "$SERVER_MD5" = "$LOCAL_MD5" ]; then
  echo "✅ File integrity verified: MD5 = $LOCAL_MD5"
else
  echo "❌ File integrity check failed!"
  echo "  Server MD5: $SERVER_MD5"
  echo "  Local MD5:  $LOCAL_MD5"
fi
```

#### 示例 3: 下载中文文件名文件（完整示例）

```bash
export JWT_TOKEN="eyJhbGc..."

# 方法 1: 手动 URL 编码
# "测试文件.txt" → "%E6%B5%8B%E8%AF%95%E6%96%87%E4%BB%B6.txt"
curl -X GET "http://localhost:8080/api/files/%E6%B5%8B%E8%AF%95%E6%96%87%E4%BB%B6.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o 测试文件_downloaded.txt

# 方法 2: 使用 Python 自动编码和下载
python3 << 'EOF'
import urllib.parse
import subprocess
import os

JWT_TOKEN = os.getenv('JWT_TOKEN')
filename = "测试文件.txt"
encoded = urllib.parse.quote(filename, safe='')

url = f"http://localhost:8080/api/files/{encoded}"
cmd = [
    'curl', '-X', 'GET', url,
    '-H', f'Authorization: Bearer {JWT_TOKEN}',
    '-o', f'{filename}_downloaded'
]

print(f"Downloading: {url}")
subprocess.run(cmd)
print(f"✅ Downloaded to {filename}_downloaded")
EOF

# 验证下载的中文文件内容
cat 测试文件_downloaded.txt
```

#### 示例 4: 批量下载多个嵌套路径文件

```bash
export JWT_TOKEN="eyJhbGc..."

# 定义要下载的文件列表
FILES=(
  "a/b/c/file1.txt"
  "data/logs/app.log"
  "scripts/main.py"
  "docs/readme.md"
)

# 批量下载
mkdir -p downloads
for file in "${FILES[@]}"; do
  echo "Downloading $file..."

  # 创建本地目录结构
  mkdir -p "downloads/$(dirname "$file")"

  # 下载文件
  curl --path-as-is -X GET "http://localhost:8080/api/files/$file" \
    -H "Authorization: Bearer ${JWT_TOKEN}" \
    -o "downloads/$file" \
    --fail --silent --show-error

  if [ $? -eq 0 ]; then
    echo "✅ $file"
  else
    echo "❌ Failed to download $file"
  fi
done

echo "All downloads completed. Files saved to downloads/"
```

---

### 6. 列出文件

**描述**: 列出指定目录下的文件和子目录。

**请求**:
```
GET /api/files?path={directory_path}
Authorization: Bearer <JWT>
```

**参数**:
- `path` (query, 必需): 目录路径（相对于工作目录）
  - 列出根目录: `path=.` 或 `path=/`
  - 列出子目录: `path=subdir` 或 `path=a/b/c`
  - 支持中文路径: `path=测试目录`

**响应**:
```json
{
  "files": [
    {
      "name": "test.txt",
      "size": 1024,
      "modified": "2026-02-11T10:35:20Z",
      "mode": "-rw-r--r--",
      "is_dir": false
    },
    {
      "name": "subdir",
      "size": 4096,
      "modified": "2026-02-11T10:30:00Z",
      "mode": "drwxr-xr-x",
      "is_dir": true
    }
  ]
}
```

**字段说明**:
- `name`: 文件/目录名
- `size`: 大小（字节）
- `modified`: 修改时间（RFC3339 格式）
- `mode`: 权限模式（Unix 格式字符串）
- `is_dir`: 是否为目录

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# 列出根目录
curl -X GET "http://localhost:8080/api/files?path=." \
  -H "Authorization: Bearer ${JWT_TOKEN}"

# 列出子目录
curl -X GET "http://localhost:8080/api/files?path=data/logs" \
  -H "Authorization: Bearer ${JWT_TOKEN}"

# 列出中文目录（需要 URL 编码）
curl -X GET "http://localhost:8080/api/files?path=%E6%B5%8B%E8%AF%95%E7%9B%AE%E5%BD%95" \
  -H "Authorization: Bearer ${JWT_TOKEN}"

# 格式化输出（使用 jq）
curl -X GET "http://localhost:8080/api/files?path=." \
  -H "Authorization: Bearer ${JWT_TOKEN}" | jq '.'
```

---

### 7. 上传文件夹

**描述**: 批量上传多个文件，保持目录结构。

**请求**:
```
POST /api/directories
Authorization: Bearer <JWT>
Content-Type: application/json

{
  "base_path": "my_project",
  "files": [
    {
      "path": "src/main.py",
      "content": "cHJpbnQoImhlbGxvIik=",
      "mode": "644"
    },
    {
      "path": "src/utils.py",
      "content": "ZGVmIGhlbHAoKToKICAgIHBhc3M=",
      "mode": "644"
    },
    {
      "path": "README.md",
      "content": "IyBQcm9qZWN0",
      "mode": "644"
    }
  ]
}
```

**参数**:
- `base_path` (string, 可选): 基础目录路径，所有文件都会上传到此目录下
- `files` (array, 必需): 文件列表，每个文件包含：
  - `path` (string, 必需): 相对于 base_path 的文件路径
  - `content` (string, 必需): Base64 编码的文件内容
  - `mode` (string, 可选): 文件权限（八进制字符串），默认 `644`

**响应**:
```json
{
  "uploaded_files": [
    {
      "path": "my_project/src/main.py",
      "size": 15,
      "mode": "-rw-r--r--",
      "modified": "2026-02-11T10:35:20Z"
    },
    {
      "path": "my_project/src/utils.py",
      "size": 20,
      "mode": "-rw-r--r--",
      "modified": "2026-02-11T10:35:20Z"
    },
    {
      "path": "my_project/README.md",
      "size": 9,
      "mode": "-rw-r--r--",
      "modified": "2026-02-11T10:35:20Z"
    }
  ],
  "total_files": 3,
  "total_size": 44
}
```

**字段说明**:
- `uploaded_files`: 已上传的文件列表
- `total_files`: 上传的文件总数
- `total_size`: 上传的文件总大小（字节）

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# 上传简单项目结构
curl -X POST http://localhost:8080/api/directories \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "base_path": "my_app",
    "files": [
      {
        "path": "app.py",
        "content": "'"$(echo 'print("Hello World")' | base64)"'",
        "mode": "755"
      },
      {
        "path": "config.json",
        "content": "'"$(echo '{"debug": true}' | base64)"'",
        "mode": "644"
      }
    ]
  }'

# Python 脚本批量上传
python3 << 'EOF'
import json
import base64
import requests

files_to_upload = [
    ("src/main.py", "print('main')", "755"),
    ("src/lib.py", "def helper(): pass", "644"),
    ("data/config.yaml", "debug: true", "644"),
]

files = []
for path, content, mode in files_to_upload:
    files.append({
        "path": path,
        "content": base64.b64encode(content.encode()).decode(),
        "mode": mode
    })

payload = {
    "base_path": "my_project",
    "files": files
}

response = requests.post(
    "http://localhost:8080/api/directories",
    headers={"Authorization": f"Bearer {JWT_TOKEN}"},
    json=payload
)
print(json.dumps(response.json(), indent=2))
EOF
```

---

### 8. 下载文件夹

**描述**: 下载整个文件夹，自动打包为压缩文件（tar.gz 或 zip）。

**请求**:
```
GET /api/directories/{path}?format=tar.gz
Authorization: Bearer <JWT>
```

**参数**:
- `{path}`: URL 路径参数，文件夹路径
- `format` (query, 可选): 压缩格式，可选值：`tar.gz`（默认）或 `zip`

**响应**:
- 成功: 返回压缩文件（二进制流）
- 失败: 返回 JSON 错误信息

**响应头**:
```
Content-Type: application/gzip (或 application/zip)
Content-Disposition: attachment; filename="directory_name.tar.gz"
Content-Description: File Transfer
Content-Transfer-Encoding: binary
```

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# 下载文件夹为 tar.gz（默认）
curl -X GET "http://localhost:8080/api/directories/my_project" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o my_project.tar.gz

# 下载文件夹为 zip
curl -X GET "http://localhost:8080/api/directories/my_project?format=zip" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o my_project.zip

# 下载多级路径文件夹
curl -X GET "http://localhost:8080/api/directories/data/logs" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o logs.tar.gz

# 下载中文文件夹（需要 URL 编码）
curl -X GET "http://localhost:8080/api/directories/%E6%B5%8B%E8%AF%95%E7%9B%AE%E5%BD%95?format=zip" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o 测试目录.zip

# 解压下载的文件
tar -xzf my_project.tar.gz  # 解压 tar.gz
unzip my_project.zip        # 解压 zip
```

**使用场景**:
- 导出项目代码
- 备份数据目录
- 批量下载日志文件
- 打包构建产物

---

### 9. 执行Python代码

**描述**: 在 Jupyter Kernel 中执行 Python 代码，会话状态持久化。

**请求**:
```
POST /api/run_python
Authorization: Bearer <JWT>
Content-Type: application/json

{
  "code": "x = 42\nprint(f'x = {x}')"
}
```

**参数**:
- `code` (string, 必需): 要执行的 Python 代码

**响应**:
```json
{
  "status": "ok",
  "output": "x = 42\n",
  "execution_count": 1,
  "execution_time": "0.045s"
}
```

**字段说明**:
- `status`: 执行状态
  - `ok`: 成功
  - `error`: 失败
- `output`: 输出内容（stdout + 返回值）
- `error`: 错误信息（如果 status 为 error）
- `traceback`: 错误堆栈（如果有）
- `execution_count`: 执行计数（会话内递增）
- `execution_time`: 执行时间

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# 简单计算
curl -X POST http://localhost:8080/api/run_python \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "code": "result = 2 + 2\nprint(f\"2 + 2 = {result}\")"
  }'

# 定义变量（持久化）
curl -X POST http://localhost:8080/api/run_python \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "code": "x = 100\ny = 200\nprint(f\"x={x}, y={y}\")"
  }'

# 使用之前定义的变量
curl -X POST http://localhost:8080/api/run_python \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "code": "z = x + y\nprint(f\"z = {z}\")"
  }'

# 使用标准库
curl -X POST http://localhost:8080/api/run_python \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "code": "import math\nprint(f\"pi = {math.pi}\")"
  }'

# 定义函数
curl -X POST http://localhost:8080/api/run_python \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "code": "def fibonacci(n):\n    if n <= 1:\n        return n\n    return fibonacci(n-1) + fibonacci(n-2)\n\nprint(f\"fib(10) = {fibonacci(10)}\")"
  }'

# 文件操作
curl -X POST http://localhost:8080/api/run_python \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "code": "import json\ndata = {\"name\": \"PicoD\", \"version\": \"1.0\"}\nwith open(\"data.json\", \"w\") as f:\n    json.dump(data, f)\nprint(\"File created\")"
  }'

# 读取文件
curl -X POST http://localhost:8080/api/run_python \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "code": "import json\nwith open(\"data.json\", \"r\") as f:\n    data = json.load(f)\nprint(data)"
  }'
```

---

### 10. 执行Python文件

**描述**: 执行已上传的 Python 脚本文件。

**请求**:
```
POST /api/run_python_file
Authorization: Bearer <JWT>
Content-Type: application/json

{
  "path": "scripts/hello.py"
}
```

**参数**:
- `path` (string, 必需): Python 文件路径（相对于工作目录）

**响应**: 同 `/api/run_python`

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# 先上传 Python 文件
cat > script.py << 'EOF'
def main():
    print("Hello from Python file!")
    x = 10
    y = 20
    print(f"{x} + {y} = {x + y}")
    return x + y

result = main()
print(f"Result: {result}")
EOF

curl -X POST http://localhost:8080/api/files \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"path\": \"scripts/hello.py\",
    \"content\": \"$(cat script.py | base64 -w 0)\",
    \"mode\": \"755\"
  }"

# 执行 Python 文件
curl -X POST http://localhost:8080/api/run_python_file \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "scripts/hello.py"
  }'

# 执行多级路径文件
curl -X POST http://localhost:8080/api/run_python_file \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "path": "data/scripts/analysis.py"
  }'
```

---

### 11. 设置TTL

**描述**: 动态更新 PicoD 实例的 TTL（Time To Live）。

**请求**:
```
PUT /api/ttl
Authorization: Bearer <JWT>
Content-Type: application/json

{
  "ttl": 7200
}
```

**参数**:
- `ttl` (integer, 必需): 新的 TTL 值（秒），必须 > 0

**响应**:
```json
{
  "message": "TTL updated successfully",
  "ttl": 7200
}
```

**curl 示例**:
```bash
export JWT_TOKEN="eyJhbGc..."

# 设置 TTL 为 1 小时
curl -X PUT http://localhost:8080/api/ttl \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "ttl": 3600
  }'

# 设置 TTL 为 2 小时
curl -X PUT http://localhost:8080/api/ttl \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "ttl": 7200
  }'

# 验证 TTL 更新
curl -X GET http://localhost:8080/health
```

---

## 测试示例

### 完整测试流程

```bash
#!/bin/bash
set -e

# 配置
PICOD_URL="http://localhost:8080"
PRIVATE_KEY="private_key.pem"

# 生成 JWT (使用 Python)
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

echo "=== 1. Health Check ==="
curl -s -X GET "${PICOD_URL}/health" | jq '.'

echo -e "\n=== 2. Execute Shell Command ==="
curl -s -X POST "${PICOD_URL}/api/execute" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"command": "pwd && ls -la"}' | jq '.'

echo -e "\n=== 3. Upload File ==="
echo "Hello PicoD!" | base64 > /tmp/content.b64
CONTENT=$(cat /tmp/content.b64)
curl -s -X POST "${PICOD_URL}/api/files" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"path\": \"test.txt\", \"content\": \"${CONTENT}\", \"mode\": \"644\"}" | jq '.'

echo -e "\n=== 4. List Files ==="
curl -s -X GET "${PICOD_URL}/api/files?path=." \
  -H "Authorization: Bearer ${JWT_TOKEN}" | jq '.'

echo -e "\n=== 5. Download File ==="
curl -s -X GET "${PICOD_URL}/api/files/test.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}"

echo -e "\n=== 6. Execute Python Code ==="
curl -s -X POST "${PICOD_URL}/api/run_python" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"code": "x = 42\nprint(f\"x = {x}\")"}' | jq '.'

echo -e "\n=== 7. Upload and Execute Python File ==="
cat > /tmp/script.py << 'EOF'
import json
data = {"test": "success", "value": 123}
with open("output.json", "w") as f:
    json.dump(data, f)
print(f"Created output.json: {data}")
EOF

SCRIPT_CONTENT=$(cat /tmp/script.py | base64 -w 0)
curl -s -X POST "${PICOD_URL}/api/files" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"path\": \"script.py\", \"content\": \"${SCRIPT_CONTENT}\", \"mode\": \"755\"}" | jq '.'

curl -s -X POST "${PICOD_URL}/api/run_python_file" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"path": "script.py"}' | jq '.'

echo -e "\n=== 8. Upload Directory ==="
cat > /tmp/upload_dir.json << 'EOFJ'
{
  "base_path": "test_project",
  "files": [
    {
      "path": "main.py",
      "content": "$(echo 'print("Hello from main")' | base64 -w 0)",
      "mode": "755"
    },
    {
      "path": "lib/utils.py",
      "content": "$(echo 'def helper(): pass' | base64 -w 0)",
      "mode": "644"
    }
  ]
}
EOFJ

curl -s -X POST "${PICOD_URL}/api/directories" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/upload_dir.json | jq '.'

echo -e "\n=== 9. Download Directory ==="
curl -s -X GET "${PICOD_URL}/api/directories/test_project?format=tar.gz" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o /tmp/test_project.tar.gz
echo "Downloaded to /tmp/test_project.tar.gz"
tar -tzf /tmp/test_project.tar.gz

echo -e "\n=== 10. Set TTL ==="
curl -s -X PUT "${PICOD_URL}/api/ttl" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"ttl": 7200}' | jq '.'

echo -e "\n=== Test Completed ==="
```

### 中文和多级路径测试

```bash
#!/bin/bash
export JWT_TOKEN=$(generate_jwt)
PICOD_URL="http://localhost:8080"

# 测试多级路径
echo "=== Testing Multi-level Paths ==="
curl -X POST "${PICOD_URL}/api/files" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"path\": \"a/b/c/deep.txt\", \"content\": \"$(echo 'Deep file' | base64)\", \"mode\": \"644\"}"

curl -X GET "${PICOD_URL}/api/files/a/b/c/deep.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}"

# 测试中文文件名
echo -e "\n=== Testing Chinese Filenames ==="
curl -X POST "${PICOD_URL}/api/files" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"path\": \"测试/中文文件.txt\", \"content\": \"$(echo '中文内容测试' | base64)\", \"mode\": \"644\"}"

# 下载中文文件（URL 编码）
curl -X GET "${PICOD_URL}/api/files/%E6%B5%8B%E8%AF%95/%E4%B8%AD%E6%96%87%E6%96%87%E4%BB%B6.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}"
```

### 大文件上传下载完整测试（31MB）

```bash
#!/bin/bash
set -e

export JWT_TOKEN=$(generate_jwt)
PICOD_URL="http://localhost:8080"

echo "=== 31MB Large File Upload/Download Test ==="

# Step 1: 生成 31MB 测试文件
echo "📦 Generating 31MB test file..."
dd if=/dev/urandom of=test_31mb.bin bs=1M count=31 2>/dev/null
ORIGINAL_MD5=$(md5sum test_31mb.bin | awk '{print $1}')
echo "   Original MD5: ${ORIGINAL_MD5}"

# Step 2: 上传大文件（使用 multipart）
echo "⬆️  Uploading 31MB file via multipart..."
UPLOAD_START=$(date +%s%3N)
curl -X POST "${PICOD_URL}/api/files" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -F "path=large_files/test_31mb.bin" \
  -F "mode=644" \
  -F "file=@test_31mb.bin" \
  -s -o /dev/null -w "HTTP %{http_code} - %{time_total}s\n"
UPLOAD_END=$(date +%s%3N)
UPLOAD_TIME=$((UPLOAD_END - UPLOAD_START))
echo "   Upload completed in ${UPLOAD_TIME}ms"

# Step 3: 验证文件存在和大小
echo "🔍 Verifying file on server..."
curl -X POST "${PICOD_URL}/api/execute" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -s \
  -d '{"command": ["stat", "-c", "%s %n", "large_files/test_31mb.bin"]}' | jq -r '.stdout'

# Step 4: 计算服务器端 MD5
echo "🔐 Computing server-side MD5..."
SERVER_MD5=$(curl -X POST "${PICOD_URL}/api/execute" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -s \
  -d '{"command": ["md5sum", "large_files/test_31mb.bin"]}' | jq -r '.stdout' | awk '{print $1}')
echo "   Server MD5: ${SERVER_MD5}"

# Step 5: 下载文件
echo "⬇️  Downloading 31MB file..."
DOWNLOAD_START=$(date +%s%3N)
curl -X GET "${PICOD_URL}/api/files/large_files/test_31mb.bin" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -s -o test_31mb_downloaded.bin \
  --max-time 300
DOWNLOAD_END=$(date +%s%3N)
DOWNLOAD_TIME=$((DOWNLOAD_END - DOWNLOAD_START))
echo "   Download completed in ${DOWNLOAD_TIME}ms"

# Step 6: 验证下载文件的完整性
echo "✅ Verifying downloaded file integrity..."
DOWNLOADED_MD5=$(md5sum test_31mb_downloaded.bin | awk '{print $1}')
echo "   Downloaded MD5: ${DOWNLOADED_MD5}"

# Step 7: 比对结果
echo ""
echo "=== Integrity Check Results ==="
echo "Original MD5:   ${ORIGINAL_MD5}"
echo "Server MD5:     ${SERVER_MD5}"
echo "Downloaded MD5: ${DOWNLOADED_MD5}"

if [ "${ORIGINAL_MD5}" = "${SERVER_MD5}" ] && [ "${SERVER_MD5}" = "${DOWNLOADED_MD5}" ]; then
  echo ""
  echo "✅ SUCCESS: All MD5 hashes match!"
  echo "📊 Performance:"
  echo "   - Upload speed:   $(echo "scale=2; 31 * 1000 / ${UPLOAD_TIME}" | bc) MB/s"
  echo "   - Download speed: $(echo "scale=2; 31 * 1000 / ${DOWNLOAD_TIME}" | bc) MB/s"

  # Cleanup
  rm -f test_31mb.bin test_31mb_downloaded.bin
  echo "🧹 Cleanup completed"
else
  echo ""
  echo "❌ FAILED: MD5 mismatch detected!"
  exit 1
fi
```

### 多路径文件并发上传测试

```bash
#!/bin/bash
set -e

export JWT_TOKEN=$(generate_jwt)
PICOD_URL="http://localhost:8080"

echo "=== Multi-path Concurrent Upload Test ==="

# 准备测试目录结构
PATHS=(
  "data/logs/app.log"
  "data/logs/error.log"
  "data/logs/access.log"
  "config/app.conf"
  "config/db.conf"
  "scripts/backup.sh"
  "scripts/deploy.sh"
  "docs/api.md"
  "docs/readme.md"
  "src/main.py"
  "src/utils.py"
  "src/models/user.py"
  "src/models/session.py"
)

echo "📦 Preparing ${#PATHS[@]} test files..."

# 创建目录结构
curl -X POST "${PICOD_URL}/api/execute" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -H "Content-Type: application/json" \
  -s \
  -d '{"command": ["mkdir", "-p", "data/logs", "config", "scripts", "docs", "src/models"]}' | jq -r '.exit_code'

# 并发上传函数
upload_file() {
  local path=$1
  local content="Test content for ${path}\nTimestamp: $(date)\n"
  local content_b64=$(echo -e "$content" | base64)

  curl -X POST "${PICOD_URL}/api/files" \
    -H "Authorization: Bearer ${JWT_TOKEN}" \
    -H "Content-Type: application/json" \
    -s \
    -d "{\"path\": \"${path}\", \"content\": \"${content_b64}\", \"mode\": \"644\"}" \
    -w "✅ ${path} (%{http_code})\n" \
    -o /dev/null
}

export -f upload_file
export JWT_TOKEN PICOD_URL

# 并发上传（使用 GNU parallel 或 xargs）
START=$(date +%s%3N)

if command -v parallel &> /dev/null; then
  # 使用 GNU parallel（推荐，更快）
  printf "%s\n" "${PATHS[@]}" | parallel -j 10 upload_file
else
  # 使用 xargs（备选）
  printf "%s\n" "${PATHS[@]}" | xargs -P 10 -I {} bash -c "upload_file '{}'"
fi

END=$(date +%s%3N)
DURATION=$((END - START))

echo ""
echo "⏱️  Uploaded ${#PATHS[@]} files in ${DURATION}ms"
echo "   Average: $((DURATION / ${#PATHS[@]}))ms per file"

# 验证所有文件
echo ""
echo "🔍 Verifying all files..."
for path in "${PATHS[@]}"; do
  # 检查文件是否存在
  RESULT=$(curl -X POST "${PICOD_URL}/api/execute" \
    -H "Authorization: Bearer ${JWT_TOKEN}" \
    -H "Content-Type: application/json" \
    -s \
    -d "{\"command\": [\"test\", \"-f\", \"${path}\"]}" | jq -r '.exit_code')

  if [ "$RESULT" -eq 0 ]; then
    echo "   ✅ ${path}"
  else
    echo "   ❌ ${path} - NOT FOUND"
  fi
done

echo ""
echo "=== Test Completed ==="
```

---

## 常见问题

### Q1: 文件上传失败，报错 "http: request body too large"

**原因**: 文件超过 64MB 限制。

**解决方案**:
- 检查文件大小：`ls -lh your_file`
- 如果文件确实小于 64MB，检查是否使用了正确的 Content-Type
- Multipart 上传时，整个请求（包括表单字段）不能超过 64MB

### Q2: 下载中文文件名或多级路径文件失败

**原因**: URL 编码问题。

**解决方案**:
```bash
# 方法 1: 手动 URL 编码
# "测试.txt" -> "%E6%B5%8B%E8%AF%95.txt"
curl -X GET "http://localhost:8080/api/files/%E6%B5%8B%E8%AF%95.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}"

# 方法 2: 使用 Python 自动编码
python3 << EOF
import urllib.parse
filename = "测试/中文文件.txt"
encoded = urllib.parse.quote(filename)
print(f"curl -X GET 'http://localhost:8080/api/files/{encoded}' ...")
EOF

# 方法 3: 使用 --data-urlencode (仅适用于 query 参数)
curl -G "http://localhost:8080/api/files" \
  --data-urlencode "path=测试.txt" \
  -H "Authorization: Bearer ${JWT_TOKEN}"
```

### Q3: JWT 认证失败

**常见错误**:
1. **Token expired**: JWT 已过期，重新生成 token
2. **Invalid signature**: 私钥/公钥不匹配，检查密钥对
3. **canonical_request_sha256 mismatch**: 请求内容被篡改或计算错误

**调试步骤**:
```bash
# 1. 验证公钥是否正确加载
curl -X GET http://localhost:8080/health

# 2. 生成不包含 canonical_request_sha256 的简单 JWT 测试
# 3. 检查 JWT payload
python3 << EOF
import jwt
token = "your_jwt_token"
decoded = jwt.decode(token, options={"verify_signature": False})
print(decoded)
EOF
```

### Q4: Python 代码执行时找不到之前定义的变量

**原因**: Jupyter kernel 可能已重启或会话丢失。

**解决方案**:
- 检查服务器是否重启（通过 `/health` 查看 uptime）
- 重新定义变量
- Python 执行是有状态的，但服务器重启会丢失状态

### Q5: 文件路径安全性

**问题**: 可以访问工作目录外的文件吗？

**回答**:
- 不可以。PicoD 使用严格的路径沙箱机制
- 所有路径都被限制在工作目录内
- 尝试访问 `../../../etc/passwd` 等路径会被拒绝
- 符号链接指向外部的也会被拒绝

### Q6: 最大文件上传大小

**回答**:
- JSON + Base64: 理论上 64MB（base64 编码后约 85MB）
- Multipart: 64MB（原始文件大小）
- 建议大文件使用 multipart 方式上传

---

## 总结

本文档详细说明了 PicoD 在 Static Auth Mode 下的所有 API 接口使用方法，包括：

✅ 健康检查
✅ Shell 命令执行
✅ 文件上传/下载/列表（支持多级路径和中文）
✅ 文件夹批量上传和打包下载（tar.gz/zip）
✅ Python 代码和文件执行（会话持久化）
✅ TTL 动态配置

所有接口均通过 RSA-PSS JWT 进行认证，确保安全性。

如有问题，请参考常见问题章节或查看服务器日志。
