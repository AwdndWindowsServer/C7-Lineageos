#!/system/xbin/sh
# ============================================================
# 在手机 TWRP Terminal 里执行的提取脚本（不需要电脑）
# 用途：从原机（三星 C7 / SM-C7000, c7ltechn）提取构建 LineageOS
#       所需的 /system、/vendor、boot.img、build.prop、分区表
#
# 用法：
#   1) 手机浏览器下载本脚本到 /sdcard/Download/
#      https://raw.githubusercontent.com/AwdndWindowsServer/C7-Lineageos/main/scripts/extract-on-device.sh
#   2) 进 TWRP -> Advanced -> Terminal，执行：
#      sh /sdcard/Download/extract-on-device.sh
#   3) 结束后把 /sdcard/c7extract/ 上传到 GitHub Releases
#
# 注意：脚本必须是 POSIX sh（TWRP 无 bash），无数组、无 [[ ]]
# ============================================================

# ---------- 0. 输出目录（TWRP 里 /sdcard 可能不可用，自动回退） ----------
OUT=""
if mkdir -p /sdcard/c7extract 2>/dev/null; then
  OUT=/sdcard/c7extract
else
  mkdir -p /data/media/0/c7extract 2>/dev/null
  OUT=/data/media/0/c7extract
fi
echo "== 输出目录: $OUT =="

# ---------- 1. 挂载分区（失败不代表出错，看输出） ----------
echo "== 挂载分区 =="
mount /system 2>&1 || echo "  (system 已挂载或挂载失败)"
mount /data   2>&1 || echo "  (data 已挂载或挂载失败)"
mount /vendor 2>&1 || echo "  (无独立 vendor 分区，正常)"

# ---------- 2. 打包 /system ----------
echo "== 打包 /system（排除 media/fonts 壁纸铃声） =="
if tar -czf "$OUT/system.tar.gz" \
     --exclude='system/media' \
     --exclude='system/fonts' \
     -C / system 2>/dev/null; then
  echo "  OK: system.tar.gz"
else
  echo "  gzip 不可用，改用不压缩 tar（文件会大一些）"
  tar -cf "$OUT/system.tar" \
     --exclude='system/media' \
     --exclude='system/fonts' \
     -C / system 2>/dev/null \
  && echo "  OK: system.tar"
fi

# ---------- 3. 打包 /vendor ----------
echo "== 检查 /vendor =="
if [ -L /vendor ]; then
  echo "  /vendor 是指向 /system/vendor 的符号链接，内容已含在 system 包里，跳过"
else
  if [ -d /vendor ]; then
    tar -czf "$OUT/vendor.tar.gz" -C / vendor 2>/dev/null \
      && echo "  OK: vendor.tar.gz" \
      || echo "  vendor 打包失败（可能为空/只读），继续"
  else
    echo "  无 /vendor 目录，跳过"
  fi
fi

# ---------- 4. boot.img ----------
echo "== 提取 boot.img =="
BOOT_FOUND=0
for P in \
  /dev/block/bootdevice/by-name/boot \
  /dev/block/by-name/boot \
  /dev/block/platform/soc/bootdevice/by-name/boot \
  /dev/block/boot/by-name/boot \
  /dev/block/sda9 \
; do
  if [ -b "$P" ]; then
    echo "  发现 boot 分区: $P"
    dd if="$P" of="$OUT/boot.img" 2>/dev/null && BOOT_FOUND=1 && break
  fi
done
[ "$BOOT_FOUND" -eq 1 ] && echo "  OK: boot.img" || echo "  WARN: 未找到 boot 分区（看 partitions.txt 手动补）"

# ---------- 5. build.prop + 分区表 ----------
echo "==== 分区表 / build.prop =="
cp /system/build.prop "$OUT/build.prop" 2>/dev/null && echo "  OK: build.prop" \
  || echo "  WARN: build.prop 复制失败"

ls -la /dev/block/bootdevice/by-name/ > "$OUT/partitions.txt" 2>/dev/null \
  || ls -la /dev/block/by-name/ > "$OUT/partitions.txt" 2>/dev/null \
  || echo "没有标准的 by-name 目录" > "$OUT/partitions.txt"
echo "  -- /dev 下的 block 设备 --"
ls -la /dev/block/ >> "$OUT/partitions.txt" 2>/dev/null || true
cat "$OUT/partitions.txt"

# ---------- 6. 汇总 ----------
echo "=============================================="
echo "== 提取完成，输出目录: $OUT =="
ls -lh "$OUT"
du -sh "$OUT" 2>/dev/null || true
echo "== 上传方法（手机浏览器）：=="
echo "  1. 打开 https://github.com/AwdndWindowsServer/C7-Lineageos/releases/new"
echo "  2. 先填 Release title（随意，比如 stock-extract）"
echo "  3. 把 $OUT 里的文件全选、上传，然后 Publish release"
echo "  4. 把发布页链接发给构建脚本作者"
echo "=============================================="