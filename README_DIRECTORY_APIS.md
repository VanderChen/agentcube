# PicoD 文件夹上传/下载功能

## 新增功能

PicoD 现在支持批量上传和下载文件夹，使得项目代码管理更加高效。

### 1. 批量上传文件夹

**接口**: `POST /api/directories`

批量上传多个文件，自动创建目录结构。

**请求示例**:
```json
{
  "base_path": "my_project",
  "files": [
    {
      "path": "src/main.py",
      "content": "base64_encoded_content",
      "mode": "755"
    },
    {
      "path": "src/utils.py",
      "content": "base64_encoded_content",
      "mode": "644"
    }
  ]
}
```

**响应**:
```json
{
  "uploaded_files": [
    {
      "path": "my_project/src/main.py",
      "size": 123,
      "mode": "-rwxr-xr-x",
      "modified": "2026-02-11T10:00:00Z"
    }
  ],
  "total_files": 2,
  "total_size": 300
}
```

### 2. 打包下载文件夹

**接口**: `GET /api/directories/{path}?format=tar.gz|zip`

下载整个文件夹，自动打包为 tar.gz 或 zip 格式。

**示例**:
```bash
# 下载为 tar.gz（默认）
curl -X GET "http://localhost:8080/api/directories/my_project" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o my_project.tar.gz

# 下载为 zip
curl -X GET "http://localhost:8080/api/directories/my_project?format=zip" \
  -H "Authorization: Bearer ${JWT_TOKEN}" \
  -o my_project.zip
```

## 使用场景

- **项目部署**: 一次性上传整个项目代码
- **代码备份**: 打包下载项目文件
- **批量操作**: 减少网络请求次数，提高效率
- **目录同步**: 保持本地和远程目录结构一致

## 测试

运行测试脚本验证功能：

```bash
# 运行单元测试
go test -v ./pkg/picod -run TestDirectoryUploadDownload

# 运行集成测试脚本
./test_directory_apis.sh
```

## API 文档

完整的 API 文档请参考 [PICOD_API_REFERENCE.md](./PICOD_API_REFERENCE.md)

## 技术实现

- **上传**: 支持批量文件上传，自动创建多级目录结构
- **下载**: 使用标准 tar.gz 或 zip 格式打包
- **安全**: 所有路径经过严格的沙箱验证，防止目录穿越攻击
- **性能**: 流式处理，支持大文件夹操作

## 变更日志

### 2026-02-11

- ✨ 新增 `POST /api/directories` 批量上传文件夹接口
- ✨ 新增 `GET /api/directories/{path}` 打包下载文件夹接口
- ✅ 添加完整的单元测试覆盖
- 📝 更新 API 参考文档
