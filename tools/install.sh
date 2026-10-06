#!/system/bin/sh
# fpgesture installer - run as root (dsh-native shell). Idempotent.
S=/data/data/top.funcun.dshfolk/files/rootfs/root/projects/fpgesture
DST=/data/local/tmp/fpgesture.sh
cp -f "$S/fpgesture.sh" "$DST" || exit 1
chmod 755 "$DST"
chmod 777 "$S" 2>/dev/null
mkdir -p /data/adb/service.d
cat > /data/adb/service.d/fpgesture.sh <<INNER
#!/system/bin/sh
# KernelSU late_start: fingerprint-key gesture daemon + its web UI
sleep 20
setsid /data/local/tmp/fpgesture.sh run </dev/null >/dev/null 2>&1 &
R=/data/data/top.funcun.dshfolk/files/rootfs
LD=\$R/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1
setsid "\$LD" --library-path "\$R/lib/aarch64-linux-gnu:\$R/usr/lib/aarch64-linux-gnu:\$R/lib:\$R/usr/lib" "\$R/usr/local/bin/node" "$S/ui-server.js" </dev/null >/dev/null 2>&1 &
INNER
chmod 755 /data/adb/service.d/fpgesture.sh
"$DST" restart
echo "installed:"; ls -l "$DST" /data/adb/service.d/fpgesture.sh; echo "--- service.d ---"; cat /data/adb/service.d/fpgesture.sh
