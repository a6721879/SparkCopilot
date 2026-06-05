#!/bin/bash
# install_ca.sh
# 自动化安装抓包 CA 证书到安卓系统证书夹的脚本

TARGET_FILE="ca.pem"

if [ ! -f "$TARGET_FILE" ]; then
    echo "❌ 错误: 未在当前目录下找到 $TARGET_FILE 文件！"
    echo "💡 请从您的抓包工具中导出 PEM 格式证书，重命名为 ca.pem 并放入当前目录后再次运行本脚本。"
    exit 1
fi

echo "🔍 正在计算证书哈希值..."
# 获取旧版 Openssl 的哈希标签值（安卓系统证书所必须的 8 位 16 进制名称）
HASH=$(openssl x509 -subject_hash_old -in "$TARGET_FILE" | head -n 1)

if [ -z "$HASH" ]; then
    echo "❌ 错误: 无法解析证书哈希值，请确认 ca.pem 是合法的 PEM 格式证书。"
    exit 1
fi

RENAME_FILE="${HASH}.0"
echo "✅ 证书哈希标签为: $HASH, 转换为临时文件: $RENAME_FILE"
cp "$TARGET_FILE" "$RENAME_FILE"

echo "🤖 正在尝试以 Root 权限连接已连线的安卓设备..."
adb root
if [ $? -ne 0 ]; then
    echo "❌ 错误: 'adb root' 命令执行失败。"
    echo "💡 请确认您的安卓设备/模拟器已经在设置中开启了 Root 权限！"
    rm -f "$RENAME_FILE"
    exit 1
fi

echo "🔓 正在将系统 System 分区挂载为可读写 (remount)..."
adb remount
if [ $? -ne 0 ]; then
    echo "❌ 错误: 'adb remount' 失败。"
    echo "💡 如果使用的是模拟器，请检查设置中是否开启了“System分区可写入”；若使用的是真机，部分系统需要解锁 system lock。"
    rm -f "$RENAME_FILE"
    exit 1
fi

echo "📤 正在将证书推送至安卓系统证书夹目录..."
adb push "$RENAME_FILE" /system/etc/security/cacerts/
if [ $? -ne 0 ]; then
    echo "❌ 错误: 推送证书文件失败。"
    rm -f "$RENAME_FILE"
    exit 1
fi

echo "🛡️ 正在修改证书的系统文件读取权限为 644..."
adb shell chmod 644 /system/etc/security/cacerts/"$RENAME_FILE"

# 清理临时文件
rm -f "$RENAME_FILE"

echo "✨ 恭喜！系统证书已经成功导入到安卓设备中！"
echo "🔄 正在为您自动重启安卓设备以激活最新的系统证书..."
adb reboot
echo "🎉 重启指令已下达，设备正在重启。重启完成后，您就可以打开 App 顺畅进行 HTTPS 代理抓包了！"
