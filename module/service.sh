#!/system/bin/sh
# KernelSU late_start service: 启动指纹手势守护进程（自包含，不依赖任何 app/容器）
MOD=/data/adb/modules/fpgesture
DATA=/data/adb/fpgesture
mkdir -p "$DATA"
[ -f "$DATA/config" ] || cp -f "$MOD/config.default" "$DATA/config" 2>/dev/null
sleep 15
setsid "$MOD/fpgesture.sh" run </dev/null >/dev/null 2>&1 &
