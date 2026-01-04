# PicoD 测试快速开始指南

## 一键运行测试

最简单的方式是使用自动化脚本：

```bash
./run_picod_test.sh
```

这个脚本会自动完成：
1. ✅ 生成测试密钥对
2. ✅ 构建 PicoD Docker 镜像
3. ✅ 启动 PicoD 容器
4. ✅ 检查并安装 Python 依赖
5. ✅ 运行完整测试套件
6. ✅ 自动清理资源

## 脚本选项

```bash
# 跳过镜像构建（如果已经构建过）
./run_picod_test.sh --skip-build

# 测试后保留容器（用于调试）
./run_picod_test.sh --skip-cleanup

# 显示容器日志
./run_picod_test.sh --logs

# 查看帮助
./run_picod_test.sh --help
```

## 手动运行步骤

如果你想手动控制每个步骤：

### 1. 生成密钥对

```bash
# 生成私钥
openssl genrsa -out /tmp/bootstrap_private_key.pem 2048

# 生成公钥
openssl rsa -in /tmp/bootstrap_private_key.pem -pubout -out /tmp/bootstrap_public_key.pem
```

### 2. 构建镜像

```bash
docker build -f docker/Dockerfile.picod -t picod:test .
```

### 3. 启动容器

```bash
docker run -d --name picod-test \
  -p 8080:8080 \
  -v /tmp/bootstrap_public_key.pem:/etc/picod/public-key.pem \
  -e PICOD_DEFAULT_TTL=3600 \
  picod:test
```

### 4. 安装 Python 依赖

```bash
pip3 install requests cryptography pyjwt
```

### 5. 运行测试

```bash
python3 test_picod.py
```

### 6. 清理

```bash
docker stop picod-test
docker rm picod-test
```

## 测试内容

测试脚本会验证以下功能：

| 测试项 | 描述 | 验证内容 |
|--------|------|----------|
| **健康检查** | 服务状态检查 | 服务可用性、TTL、运行时间 |
| **Python 执行** | 7 轮代码执行 | 代码执行、状态持久化、库导入 |
| **文件操作** | 文件上传/下载 | 文件 API、权限、内容完整性 |
| **命令执行** | Shell 命令 | 命令执行、输出捕获、退出码 |
| **Python I/O** | 文件读写 | Python 文件操作、JSON 处理 |

## 预期输出

成功运行时，你会看到：

```
╔══════════════════════════════════════════════════════════════════╗
║                  PicoD Standalone Test Suite                     ║
╚══════════════════════════════════════════════════════════════════╝

🔑 Generating session RSA key pair...
✅ Session keys generated
🚀 Initializing PicoD...
✅ PicoD initialized successfully

======================================================================
  TEST 1: Health Check
======================================================================
✅ Health Status: ok

======================================================================
  TEST 2: Python Code Execution (Multiple Rounds)
======================================================================
  Round 1: Simple arithmetic
  ✅ Status: ok
  ...
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

## 常见问题

### Q: 端口 8080 被占用怎么办？

**A:** 修改端口映射：

```bash
# 使用不同端口
docker run -d --name picod-test \
  -p 9090:8080 \
  -v /tmp/bootstrap_public_key.pem:/etc/picod/public-key.pem \
  picod:test

# 设置环境变量
export PICOD_URL=http://localhost:9090
python3 test_picod.py
```

### Q: 测试失败怎么调试？

**A:** 查看容器日志：

```bash
# 查看实时日志
docker logs -f picod-test

# 或使用脚本选项
./run_picod_test.sh --logs --skip-cleanup
```

### Q: 如何只测试特定功能？

**A:** 修改 `test_picod.py` 中的 `main()` 函数，注释掉不需要的测试：

```python
# 只运行 Python 执行测试
results = []
# results.append(('Health Check', test_health_check(client)))
results.append(('Python Execution', test_python_execution(client)))
# results.append(('File Operations', test_file_operations(client)))
```

### Q: 如何在 CI/CD 中使用？

**A:** 示例 GitHub Actions 配置：

```yaml
name: PicoD Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Set up Python
        uses: actions/setup-python@v2
        with:
          python-version: '3.10'
      
      - name: Run PicoD Tests
        run: |
          chmod +x run_picod_test.sh
          ./run_picod_test.sh
```

## 下一步

- 📖 阅读完整文档：[README_TEST_PICOD.md](README_TEST_PICOD.md)
- 🔍 查看源码分析：测试脚本基于对 PicoD 源码的深入分析
- 🛠️ 自定义测试：根据你的需求扩展测试用例
- 🐛 报告问题：如果发现 bug，请提交 issue

## 技术支持

如果遇到问题：

1. 检查 Docker 是否正常运行
2. 确认 Python 3.7+ 已安装
3. 查看容器日志排查错误
4. 参考完整文档获取更多信息

---

**提示**: 这个测试脚本完全独立，不依赖任何 proposal 或其他测试文件，可以直接用于验证 PicoD 镜像的功能。
