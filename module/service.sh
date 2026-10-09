#!/system/bin/sh
# KernelSU late_start service: 启动指纹手势守护进程（自包含，不依赖任何 app/容器）
MOD=/data/adb/modules/fpgesture
DATA=/data/adb/fpgesture
mkdir -p "$DATA"
[ -f "$DATA/config" ] || cp -f "$MOD/config.default" "$DATA/config" 2>/dev/null
# 确保守护脚本可执行（zip 在某些打包方式下会丢失 +x，KSU 只自动给 service.sh 提权，
# 不会给 fpgesture.sh 提权，因此这里兜底 chmod，避免「顶部显示未运行」）
chmod 0755 "$MOD/fpgesture.sh" 2>/dev/null
chmod 0755 "$MOD"/*.sh 2>/dev/null
sleep 15
setsid "$MOD/fpgesture.sh" run </dev/null >/dev/null 2>&1 &
