# PicoD 独立测试脚本

这是一个针对 PicoD 镜像的独立测试脚本，不依赖于 proposal 和其他测试文件。

## 功能特性

测试脚本 `test_picod.py` 提供以下测试功能：

1. **健康检查** - 验证 PicoD 服务状态
2. **多轮 Python 代码执行** - 测试 Python 代码执行能力和状态持久化
3. **文件操作** - 上传、下载、列表文件
4. **命令执行** - 执行 shell 命令
5. **Python 文件 I/O** - Python 代码读写文件

## 前置要求

### 1. 安装 Python 依赖

```bash
pip install requests cryptography pyjwt
```

### 2. 构建 PicoD 镜像

```bash
# 在项目根目录执行
docker build -f docker/Dockerfile.picod -t picod:latest .
```

### 3. 生成密钥对（如果还没有）

测试脚本会自动生成密钥对，但你也可以手动生成：

```bash
# 生成私钥
openssl genrsa -out /tmp/bootstrap_private_key.pem 2048

# 生成公钥
openssl rsa -in /tmp/bootstrap_private_key.pem -pubout -out /tmp/bootstrap_public_key.pem
```

## 运行测试

### 方法 1: 使用默认配置

```bash
# 1. 启动 PicoD 容器
docker run -d --name picod-test \
  -p 8080:8080 \
  -v /tmp/bootstrap_public_key.pem:/etc/picod/public-key.pem \
  picod:latest

# 2. 运行测试脚本
python3 test_picod.py
```

### 方法 2: 自定义配置

```bash
# 设置环境变量
export PICOD_URL=http://localhost:8080
export BOOTSTRAP_KEY_PATH=/path/to/your/bootstrap_private_key.pem

# 运行测试
python3 test_picod.py
```

### 方法 3: 使用 Docker Compose

创建 `docker-compose.test.yml`:

```yaml
version: '3.8'

services:
  picod:
    image: picod:latest
    ports:
      - "8080:8080"
    volumes:
      - /tmp/bootstrap_public_key.pem:/etc/picod/public-key.pem
    environment:
      - PICOD_DEFAULT_TTL=3600
```

运行：

```bash
docker-compose -f docker-compose.test.yml up -d
python3 test_picod.py
docker-compose -f docker-compose.test.yml down
```

## 测试内容详解

### 测试 1: 健康检查

验证 PicoD 服务的健康状态，包括：
- 服务状态
- 运行时间
- 初始化状态
- TTL 配置
- 空闲时间

### 测试 2: Python 代码执行（多轮）

执行 7 轮不同的 Python 代码测试：

1. **简单算术** - 基本计算
2. **变量持久化** - 定义变量
3. **使用之前的变量** - 验证状态持久化
4. **列表操作** - 列表推导式
5. **导入库** - 使用标准库
6. **定义函数** - 递归函数
7. **数据操作** - 字典操作

这些测试验证了：
- Python 代码执行能力
- 会话状态持久化
- 变量在多次执行间的保持
- 标准库可用性

### 测试 3: 文件操作

测试文件系统操作：

1. **上传文本文件** - 上传简单文本
2. **上传 Python 脚本** - 上传可执行脚本
3. **列出文件** - 查看目录内容
4. **下载文件** - 下载并验证内容
5. **执行脚本** - 运行上传的 Python 脚本

### 测试 4: 命令执行

执行多个 shell 命令：

1. `ls -la` - 列出目录
2. `pwd` - 打印工作目录
3. `echo` - 输出测试
4. `python3 --version` - 检查 Python 版本
5. 复合命令 - 创建和读取文件

### 测试 5: Python 文件 I/O

测试 Python 代码的文件读写能力：

1. 使用 Python 创建 JSON 文件
2. 使用 Python 读取 JSON 文件
3. 通过 API 验证文件存在

## 测试输出示例

```
╔══════════════════════════════════════════════════════════════════╗
║                  PicoD Standalone Test Suite                     ║
║                                                                  ║
║  Testing PicoD service independently without proposals           ║
╚══════════════════════════════════════════════════════════════════╝

📍 PicoD URL: http://localhost:8080
🔑 Bootstrap Key: /tmp/bootstrap_private_key.pem

🔑 Generating session RSA key pair...
✅ Session keys generated
🔑 Loading bootstrap key from /tmp/bootstrap_private_key.pem...
✅ Bootstrap keys loaded

⏳ Waiting for PicoD to be ready...
✅ PicoD is ready! Status: ok

🚀 Initializing PicoD...
✅ PicoD initialized successfully

======================================================================
  TEST 1: Health Check
======================================================================
✅ Health Status: ok
   Service: PicoD
   Uptime: 5s
   Initialized: True
   TTL: 900s
   Idle: 0s

======================================================================
  TEST 2: Python Code Execution (Multiple Rounds)
======================================================================

  Round 1: Simple arithmetic
  Code: result = 2 + 2\nprint(f"2 + 2 = {result}")...
  ✅ Status: ok
     Output: 2 + 2 = 4
     Execution Count: 1
     Duration: 0.123s

  Round 2: Variable persistence
  Code: x = 100\ny = 200\nprint(f"x={x}, y={y}")...
  ✅ Status: ok
     Output: x=100, y=200
     Execution Count: 2
     Duration: 0.089s

  Round 3: Use previous variables
  Code: z = x + y\nprint(f"x + y = {z}")...
  ✅ Status: ok
     Output: x + y = 300
     Execution Count: 3
     Duration: 0.076s

  Summary: 7/7 tests passed

======================================================================
  TEST SUMMARY
======================================================================
  ✅ PASS  Health Check
  ✅ PASS  Python Execution
  ✅ PASS  File Operations
  ✅ PASS  Command Execution
  ✅ PASS  Python File I/O

  Total: 5/5 tests passed

🎉 All tests passed!
```

## 故障排查

### 问题 1: 连接被拒绝

```
❌ PicoD not accessible after 10 retries
```

**解决方案**:
- 确认 PicoD 容器正在运行: `docker ps | grep picod`
- 检查端口映射是否正确
- 查看容器日志: `docker logs picod-test`

### 问题 2: 初始化失败

```
❌ Initialization failed: 401
```

**解决方案**:
- 确认 bootstrap 公钥已正确挂载到容器
- 验证私钥和公钥是否匹配
- 检查密钥文件权限

### 问题 3: Python 执行不可用

```
❌ Python code execution is not available
```

**解决方案**:
- 确认使用的是 `picod:latest` 镜像（包含 Jupyter）
- 检查容器内是否安装了 `jupyter-server`
- 查看容器启动日志

## 环境变量

测试脚本支持以下环境变量：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PICOD_URL` | `http://localhost:8080` | PicoD 服务地址 |
| `BOOTSTRAP_KEY_PATH` | `/tmp/bootstrap_private_key.pem` | Bootstrap 私钥路径 |

PicoD 容器支持的环境变量：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PICOD_DEFAULT_TTL` | `900` | 默认 TTL（秒） |
| `PICOD_AUTH_MODE` | `dynamic` | 认证模式（dynamic/static） |

## 清理

测试完成后清理资源：

```bash
# 停止并删除容器
docker stop picod-test
docker rm picod-test

# 删除生成的密钥（可选）
rm /tmp/bootstrap_private_key.pem
rm /tmp/bootstrap_public_key.pem
```

## 技术细节

### 认证机制

测试脚本实现了 PicoD 的完整认证流程：

1. **Bootstrap 阶段**: 使用 bootstrap 密钥对初始化 PicoD
2. **Session 阶段**: 使用 session 密钥对进行后续请求
3. **JWT 签名**: 使用 PS256 (RSA-PSS) 算法
4. **请求完整性**: 通过 canonical request hash 验证

### 源码阅读

测试脚本基于对以下 PicoD 源码的分析：

- `pkg/picod/server.go` - 服务器主逻辑和路由
- `pkg/picod/auth.go` - 认证和 JWT 验证
- `pkg/picod/python.go` - Python 代码执行
- `pkg/picod/execute.go` - 命令执行
- `pkg/picod/files.go` - 文件操作
- `pkg/picod/jupyter.go` - Jupyter 内核管理

## 扩展测试

你可以轻松扩展测试脚本：

```python
def test_custom_feature(client: PicodClient):
    """自定义测试"""
    print_section("TEST X: Custom Feature")
    
    try:
        # 你的测试代码
        result = client.run_python("print('Hello')")
        print(f"✅ Test passed")
        return True
    except Exception as e:
        print(f"❌ Test failed: {e}")
        return False

# 在 main() 函数中添加
results.append(('Custom Feature', test_custom_feature(client)))
```

## 许可证

本测试脚本遵循 AgentCube 项目的许可证。
