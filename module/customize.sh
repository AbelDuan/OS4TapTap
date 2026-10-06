#!/system/bin/sh
# 安装时执行（KernelSU zip 安装）
mkdir -p /data/adb/fpgesture
[ -f /data/adb/fpgesture/config ] || cp -f "$MODPATH/config.default" /data/adb/fpgesture/config 2>/dev/null
ui_print "- 指纹手势模块已安装，WebUI 在模块页「打开」按钮"
