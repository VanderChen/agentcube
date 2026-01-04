#!/bin/bash
# PicoD 测试运行脚本
# 此脚本自动化 PicoD 的构建、启动和测试流程

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
PICOD_IMAGE="picod:test"
CONTAINER_NAME="picod-test"
PICOD_PORT="8080"
BOOTSTRAP_PRIVATE_KEY="/tmp/bootstrap_private_key.pem"
BOOTSTRAP_PUBLIC_KEY="/tmp/bootstrap_public_key.pem"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           PicoD 自动化测试脚本                                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# 函数：清理资源
cleanup() {
    echo -e "\n${YELLOW}🧹 清理资源...${NC}"
    
    # 停止并删除容器
    if docker ps -a | grep -q "$CONTAINER_NAME"; then
        echo "  停止容器: $CONTAINER_NAME"
        docker stop "$CONTAINER_NAME" 2>/dev/null || true
        docker rm "$CONTAINER_NAME" 2>/dev/null || true
    fi
    
    echo -e "${GREEN}✅ 清理完成${NC}"
}

# 函数：生成密钥对
generate_keys() {
    echo -e "${BLUE}🔑 生成 Bootstrap 密钥对...${NC}"
    
    if [ -f "$BOOTSTRAP_PRIVATE_KEY" ] && [ -f "$BOOTSTRAP_PUBLIC_KEY" ]; then
        echo -e "${YELLOW}  密钥已存在，跳过生成${NC}"
        return
    fi
    
    # 生成私钥
    openssl genrsa -out "$BOOTSTRAP_PRIVATE_KEY" 2048 2>/dev/null
    echo "  ✅ 生成私钥: $BOOTSTRAP_PRIVATE_KEY"
    
    # 生成公钥
    openssl rsa -in "$BOOTSTRAP_PRIVATE_KEY" -pubout -out "$BOOTSTRAP_PUBLIC_KEY" 2>/dev/null
    echo "  ✅ 生成公钥: $BOOTSTRAP_PUBLIC_KEY"
}

# 函数：构建镜像
build_image() {
    echo -e "\n${BLUE}🔨 构建 PicoD 镜像...${NC}"
    
    if docker images | grep -q "^picod.*test"; then
        echo -e "${YELLOW}  镜像已存在，是否重新构建？ (y/N)${NC}"
        read -r -t 5 response || response="n"
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "  跳过构建"
            return
        fi
    fi
    
    docker build -f docker/Dockerfile.picod -t "$PICOD_IMAGE" .
    echo -e "${GREEN}✅ 镜像构建完成${NC}"
}

# 函数：启动容器
start_container() {
    echo -e "\n${BLUE}🚀 启动 PicoD 容器...${NC}"
    
    # 检查端口是否被占用
    if lsof -Pi :$PICOD_PORT -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo -e "${RED}❌ 端口 $PICOD_PORT 已被占用${NC}"
        echo "   请先停止占用该端口的进程"
        exit 1
    fi
    
    # 启动容器
    docker run -d \
        --name "$CONTAINER_NAME" \
        -p "$PICOD_PORT:8080" \
        -v "$BOOTSTRAP_PUBLIC_KEY:/etc/picod/public-key.pem" \
        -e PICOD_DEFAULT_TTL=3600 \
        "$PICOD_IMAGE"
    
    echo "  ✅ 容器已启动: $CONTAINER_NAME"
    echo "  📍 访问地址: http://localhost:$PICOD_PORT"
    
    # 等待服务就绪
    echo -e "\n${YELLOW}⏳ 等待 PicoD 服务就绪...${NC}"
    max_retries=30
    retry=0
    while [ $retry -lt $max_retries ]; do
        if curl -s "http://localhost:$PICOD_PORT/health" >/dev/null 2>&1; then
            echo -e "${GREEN}✅ PicoD 服务已就绪${NC}"
            return
        fi
        retry=$((retry + 1))
        echo -n "."
        sleep 1
    done
    
    echo -e "\n${RED}❌ PicoD 服务启动超时${NC}"
    echo "查看日志:"
    docker logs "$CONTAINER_NAME"
    exit 1
}

# 函数：检查 Python 依赖
check_dependencies() {
    echo -e "\n${BLUE}📦 检查 Python 依赖...${NC}"
    
    missing_deps=()
    
    if ! python3 -c "import requests" 2>/dev/null; then
        missing_deps+=("requests")
    fi
    
    if ! python3 -c "import cryptography" 2>/dev/null; then
        missing_deps+=("cryptography")
    fi
    
    if ! python3 -c "import jwt" 2>/dev/null; then
        missing_deps+=("pyjwt")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        echo -e "${YELLOW}  缺少依赖: ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}  正在安装...${NC}"
        pip3 install -q "${missing_deps[@]}"
        echo -e "${GREEN}  ✅ 依赖安装完成${NC}"
    else
        echo -e "${GREEN}  ✅ 所有依赖已满足${NC}"
    fi
}

# 函数：运行测试
run_tests() {
    echo -e "\n${BLUE}🧪 运行测试...${NC}"
    echo ""
    
    export PICOD_URL="http://localhost:$PICOD_PORT"
    export BOOTSTRAP_KEY_PATH="$BOOTSTRAP_PRIVATE_KEY"
    
    if python3 test_picod.py; then
        echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║                    🎉 所有测试通过！                              ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
        return 0
    else
        echo -e "\n${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                    ❌ 测试失败                                    ║${NC}"
        echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
        return 1
    fi
}

# 函数：显示日志
show_logs() {
    echo -e "\n${BLUE}📋 PicoD 容器日志:${NC}"
    docker logs "$CONTAINER_NAME" --tail 50
}

# 主流程
main() {
    # 解析参数
    SKIP_BUILD=false
    SKIP_CLEANUP=false
    SHOW_LOGS=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-cleanup)
                SKIP_CLEANUP=true
                shift
                ;;
            --logs)
                SHOW_LOGS=true
                shift
                ;;
            --help)
                echo "用法: $0 [选项]"
                echo ""
                echo "选项:"
                echo "  --skip-build     跳过镜像构建"
                echo "  --skip-cleanup   测试后不清理容器"
                echo "  --logs           显示容器日志"
                echo "  --help           显示此帮助信息"
                exit 0
                ;;
            *)
                echo -e "${RED}未知选项: $1${NC}"
                echo "使用 --help 查看帮助"
                exit 1
                ;;
        esac
    done
    
    # 注册清理函数（如果不跳过清理）
    if [ "$SKIP_CLEANUP" = false ]; then
        trap cleanup EXIT
    fi
    
    # 执行步骤
    cleanup
    generate_keys
    
    if [ "$SKIP_BUILD" = false ]; then
        build_image
    fi
    
    start_container
    check_dependencies
    
    # 运行测试
    test_result=0
    run_tests || test_result=$?
    
    # 显示日志（如果需要）
    if [ "$SHOW_LOGS" = true ]; then
        show_logs
    fi
    
    # 如果跳过清理，提示用户
    if [ "$SKIP_CLEANUP" = true ]; then
        echo -e "\n${YELLOW}⚠️  容器未清理，使用以下命令手动清理:${NC}"
        echo "  docker stop $CONTAINER_NAME"
        echo "  docker rm $CONTAINER_NAME"
    fi
    
    exit $test_result
}

# 运行主流程
main "$@"
