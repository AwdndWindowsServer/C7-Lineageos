#!/usr/bin/env bash
#
# 构建 LineageOS 16.0 (Android 9) —— 通用构建脚本（CI / 本地通用）
#
# 用法：直接执行即可，或用环境变量覆盖默认值：
#   LOS_BRANCH   源码分支            (默认 lineage-16.0)
#   DEVICE       lunch 目标设备名     (默认 j7popltespr)
#   MANIFEST     本地 manifest 路径   (默认 manifest/j7popltespr.xml)
#   TARGET       构建目标             (默认 bacon；可用 bootimage 等做快速验证)
#   SYNC_JOBS    repo sync 并行数     (默认 4)
#   BUILD_JOBS   make 并行数          (默认取 nproc)
#   USE_CCACHE   是否启用 ccache      (0/1，默认 0)
#   SRC_ROOT     源码根目录           (默认 $PWD/android)
#
# 注意：绝不能加 set -u！Android 9 的 build/envsetup.sh 在 bash 4.4+ 的
# nounset 模式下会因空数组报 "unbound variable"（envsetup.sh:1702 _xarray）。
set -eo pipefail

# ---------- 配置 ----------
LOS_BRANCH="${LOS_BRANCH:-lineage-16.0}"
DEVICE="${DEVICE:-j7popltespr}"
MANIFEST="${MANIFEST:-manifest/j7popltespr.xml}"
TARGET="${TARGET:-bacon}"
SYNC_JOBS="${SYNC_JOBS:-4}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"
USE_CCACHE="${USE_CCACHE:-0}"
SRC_ROOT="${SRC_ROOT:-$PWD/android}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log_group() { echo "::group::$*"; }
log_end()   { echo "::endgroup::"; }

# ---------- 1. git 身份 ----------
log_group "git 配置"
git config --global user.name  "${USER_NAME:-C7 CI}"
git config --global user.email "${USER_MAIL:-ci@localhost}"
log_end

# ---------- 2. Java 8（Android 9 必需） ----------
log_group "Java 8"
JAVA8="$(ls -d /usr/lib/jvm/java-8-openjdk-* 2>/dev/null | head -n1 || true)"
if [ -n "$JAVA8" ]; then
  sudo update-alternatives --set java "$JAVA8/bin/java" 2>/dev/null || true
  export JAVA_HOME="$JAVA8"
  # 直接前置 PATH，确保 `java` 解析到 8（update-alternatives 在 runner 上可能不生效）
  export PATH="$JAVA8/bin:$PATH"
else
  echo "::warning::未找到 OpenJDK 8，Android 9 构建需要它"
fi
java -version 2>&1 | head -n1
log_end

# ---------- 3. repo 工具 ----------
log_group "repo 工具"
if [ ! -x /usr/local/bin/repo ]; then
  sudo curl -sSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo
  sudo chmod a+x /usr/local/bin/repo
fi
repo --version 2>&1 | head -n1 || true
log_end

# ---------- 4. 初始化 + 同步源码 ----------
log_group "repo init / sync（可多次重试）"
mkdir -p "$SRC_ROOT"
cd "$SRC_ROOT"

if [ ! -d .repo ]; then
  repo init -u https://github.com/LineageOS/android.git -b "$LOS_BRANCH"
fi

mkdir -p .repo/local_manifests
cp "$PROJECT_ROOT/$MANIFEST" .repo/local_manifests/device.xml

for attempt in 1 2 3; do
  if repo sync -j"$SYNC_JOBS" -c --force-sync --no-clone-bundle --no-tags; then
    break
  fi
  echo "::warning::repo sync 失败（第 $attempt/3 次），重试..."
  [ "$attempt" -eq 3 ] && { echo "::error::repo sync 多次失败，退出"; exit 1; }
done
log_end

# ---------- 5. C7 专用：内核 defconfig + vendor 生成 ----------
if [ "$DEVICE" = "c7ltechn" ]; then
  log_group "C7 设备树同步"
  # manifest 用 self remote 拉本仓库到 device/samsung/c7ltechn，但 repo sync
  # 对与 CI checkout 同源的仓库可能静默跳过/失败，这里直接用 CI checkout 副本补齐。
  SYNCED_DT="$SRC_ROOT/device/samsung/c7ltechn"
  if [ ! -f "$SYNCED_DT/proprietary-files.txt" ]; then
    mkdir -p "$(dirname "$SYNCED_DT")"
    rm -rf "$SYNCED_DT"
    cp -a "$PROJECT_ROOT/device/samsung/c7ltechn" "$SYNCED_DT"
    echo "设备树已从 CI checkout 复制到 $SYNCED_DT"
  else
    echo "设备树已由 repo sync 提供"
  fi
  log_end

  log_group "C7 内核 defconfig"
  KCFG="kernel/samsung/msm8953/arch/arm64/configs/c7ltechn_defconfig"
  if [ ! -f "$KCFG" ]; then
    mkdir -p "$(dirname "$KCFG")"
    cp "$PROJECT_ROOT/kernel/c7ltechn_defconfig" "$KCFG"
    echo "已安装 C7 defconfig"
  fi
  log_end

  log_group "C7 vendor 提取"
  EXTRACT_DIR="$SRC_ROOT/.c7extract"
  mkdir -p "$EXTRACT_DIR/system"
  C7_READY=0
  if [ -n "${C7_EXTRACT_URL:-}" ] && [ ! -f "$EXTRACT_DIR/system/vendor/etc/fstab.qcom" ]; then
    curl -fL --retry 3 -o "$EXTRACT_DIR/system.tar.gz" "$C7_EXTRACT_URL" \
      && tar xzf "$EXTRACT_DIR/system.tar.gz" -C "$EXTRACT_DIR" \
      && C7_READY=1 || echo "::warning::C7 提取包下载失败，回退 j7 blobs"
  fi

  PROP_LIST="$SRC_ROOT/device/samsung/c7ltechn/proprietary-files.txt"
  J7_PROP="$SRC_ROOT/vendor/samsung/j7popltespr/proprietary"
  while IFS= read -r line; do
    case "$line" in ""|"#"*) continue;; esac
    line="${line%%|*}"
    src="${line%%:*}"; dest="${line#*:}"
    [ "$src" = "$line" ] && dest="$src"
    sfile="$EXTRACT_DIR/system/$src"
    jfile="$J7_PROP/$dest"
    if [ -f "$sfile" ]; then
      [ "$C7_READY" = "0" ] && echo "保留 C7 旧缓存: $src"
    elif [ -f "$jfile" ]; then
      mkdir -p "$(dirname "$sfile")"
      cp "$jfile" "$sfile"
      echo "fallback(j7): $src"
    else
      echo "::warning::$src 在提取包与 j7 vendor 中均缺失"
    fi
  done < "$PROP_LIST"

  if [ -f "$EXTRACT_DIR/system/vendor/etc/fstab.qcom" ] || compgen -G "$EXTRACT_DIR/system/vendor/lib/*.so" >/dev/null; then
    # 必须在 repo sync 后的设备树目录里跑：extract-files.sh 用相对路径
    # ../../.. 找 $SRC_ROOT/vendor/lineage/build/tools/extract_utils.sh
    ( cd "$SRC_ROOT/device/samsung/c7ltechn" && ./extract-files.sh "$EXTRACT_DIR" )
  else
    echo "::error::C7 vendor 生成失败：无任何 blob 可用"
    exit 1
  fi
  log_end
fi

# ---------- 6. 老内核宿主工具兼容 ----------
# 3.18 内核的 scripts/dtc 在 GCC 10+（默认 -fno-common）下链接报
#   "multiple definition of `yylloc'"
# 修复：给内核宿主编译器加 -fcommon（环境变量 + 保险的文件补丁双保险）
log_group "内核宿主工具兼容 (-fcommon)"
export HOST_EXTRACFLAGS="-fcommon"
KERNEL_MH="kernel/samsung/msm8953/scripts/Makefile.host"
if [ -f "$KERNEL_MH" ] && ! grep -q -- "-fcommon" "$KERNEL_MH"; then
  sed -i 's/^KBUILD_HOSTCFLAGS = /KBUILD_HOSTCFLAGS = -fcommon /' "$KERNEL_MH" || true
  echo "已补丁 $KERNEL_MH"
fi
log_end

# ---------- 6. 加载环境 + 选择产品 ----------
log_group "envsetup / lunch"
source build/envsetup.sh
lunch "lineage_${DEVICE}-userdebug"
log_end

# ---------- 7. ccache（可选） ----------
if [ "$USE_CCACHE" = "1" ]; then
  export USE_CCACHE=1 CCACHE_DIR="$SRC_ROOT/.ccache"
  prebuilts/misc/linux-x86/ccache/ccache -M 20G
fi

# ---------- 8. 编译 ----------
log_group "mka $TARGET -j$BUILD_JOBS"
set +e
mka "$TARGET" -j"$BUILD_JOBS" 2>&1 | tee "$SRC_ROOT/build.log"
status=${PIPESTATUS[0]}
set -e
log_end

if [ "$status" -ne 0 ]; then
  echo "::error::构建失败 (exit $status)，build.log 末尾："
  tail -n 40 "$SRC_ROOT/build.log" || true
  exit "$status"
fi

# ---------- 9. 产物 ----------
echo "=== 构建产物 ==="
ls -lh out/target/product/"$DEVICE"/lineage_*.zip 2>/dev/null || true
echo "=== 完成 ==="
