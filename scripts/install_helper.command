#!/bin/bash
set -e

# Donby macOS 一键极速安装 / 更新与免验证助手
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_APP="${SCRIPT_DIR}/Donby.app"
TARGET_DIR="/Applications"
TARGET_APP="${TARGET_DIR}/Donby.app"

echo "======================================================"
echo "          Donby macOS 一键安装 / 更新助手"
echo "======================================================"
echo ""

if [ ! -d "$SOURCE_APP" ]; then
    echo "❌ 错误: 未在当前镜像目录找到 Donby.app"
    echo "请直接在 DMG 虚拟磁盘中双击运行本脚本。"
    echo ""
    read -p "按回车键退出..." dummy
    exit 1
fi

# 1. 退出正在运行的旧版本 Donby 进程
if pgrep -x "Donby" >/dev/null 2>&1; then
    echo "==> 正在退出运行中的旧版本 Donby..."
    pkill -x "Donby" || true
    sleep 1
fi

# 2. 清理旧版本及可能的系统重名残留 (Donby 2.app 等)
echo "==> 清理旧版本残留与可能存在的重名副本..."
rm -rf "$TARGET_APP" 2>/dev/null || true
rm -rf "${TARGET_DIR}/Donby 2.app" "${TARGET_DIR}/Donby 3.app" 2>/dev/null || true

# 3. 复制最新版到 /Applications
echo "==> 正在将最新版 Donby.app 安装至 /Applications..."
cp -R "$SOURCE_APP" "$TARGET_DIR/"

# 4. 解除 macOS Gatekeeper 安全隔离 (解决'无法验证开发者'与'重新手动验证')
echo "==> 移除 macOS Gatekeeper 安全隔离属性 (免去安全与隐私手动验证)..."
xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

# 5. 刷新 LaunchServices 注册表，强制系统识别最新版本并清除旧版本索引
echo "==> 刷新 macOS 启动服务与应用版本注册表..."
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$TARGET_APP" 2>/dev/null || true
fi

echo ""
echo "======================================================"
echo "🎉 安装与更新完成！"
echo "   - 旧版本残留已完全清理"
echo "   - 安全隔离限制已解除 (无需进入安全与隐私手动验证)"
echo "======================================================"
echo ""

read -p "是否立即启动 Donby？(Y/n): " launch_choice
launch_choice="${launch_choice:-Y}"
if [[ "$launch_choice" =~ ^[Yy]$ ]]; then
    open "$TARGET_APP"
fi
