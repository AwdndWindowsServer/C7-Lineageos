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

# 自愈辅助：检查必需文件/目录，缺失时自动执行修复命令，修好继续，修不好才报错退出。
# 用法:
#   ensure_file  <文件路径> <说明> [修复命令(可含 bash -c ...)]
#   ensure_dir   <目录路径> <说明> [修复命令...]
ensure_file() {
  local f="$1" desc="$2"; shift 2
  [ -f "$f" ] && return 0
  if [ "$#" -gt 0 ]; then
    echo "::warning::缺少文件 $f（$desc），自动修复: $*"
    if eval "$*"; then
      if [ -f "$f" ]; then echo "::notice::自动修复成功: $f"; return 0; fi
      echo "::error::自动修复命令执行了，但 $f 仍不存在"
    else
      echo "::error::自动修复命令执行失败: $*"
    fi
  else
    echo "::error::缺少必需文件 $f（$desc），且没有自动修复方案"
  fi
  echo "::error::请人工检查 $f 后重新运行构建"
  exit 1
}
ensure_dir() {
  local d="$1" desc="$2"; shift 2
  [ -d "$d" ] && return 0
  if [ "$#" -gt 0 ]; then
    echo "::warning::缺少目录 $d（$desc），自动修复: $*"
    if eval "$*"; then
      if [ -d "$d" ]; then echo "::notice::自动修复成功: $d"; return 0; fi
      echo "::error::自动修复命令执行了，但 $d 仍不存在"
    else
      echo "::error::自动修复命令执行失败: $*"
    fi
  else
    echo "::error::缺少必需目录 $d（$desc），且没有自动修复方案"
  fi
  echo "::error::请人工检查 $d 后重新运行构建"
  exit 1
}

# ---------- 1. git 身份 ----------
log_group "git 配置"
git config --global user.name  "${USER_NAME:-C7 CI}"
git config --global user.email "${USER_MAIL:-ci@localhost}"
log_end

# ---------- 2. Java 8（Android 9 必需） ----------
log_group "Java 8"
JAVA8="$(ls -d /usr/lib/jvm/java-8-openjdk-* 2>/dev/null | head -n1 || true)"
if [ -z "$JAVA8" ]; then
  echo "::warning::未找到 OpenJDK 8，尝试安装（Semaphore 镜像预装 11/17）"
  sudo apt-get update -qq 2>/dev/null || true
  sudo apt-get install -y -qq openjdk-8-jdk 2>&1 | tail -1 || true
  JAVA8="$(ls -d /usr/lib/jvm/java-8-openjdk-* 2>/dev/null | head -n1 || true)"
fi
if [ -n "$JAVA8" ]; then
  sudo update-alternatives --set java "$JAVA8/bin/java" 2>/dev/null || true
  export JAVA_HOME="$JAVA8"
  # 直接前置 PATH，确保 `java` 解析到 8（update-alternatives 在 runner 上可能不生效）
  export PATH="$JAVA8/bin:$PATH"
else
  echo "::error::无法获得 OpenJDK 8，Android 9 构建需要它"
  echo "::error::请确认 runner 系统是 Ubuntu 22.04 且 apt 源可访问 openjdk-8-jdk"
  exit 1
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
echo "sync 后磁盘: $(df -h "$SRC_ROOT" | awk 'NR==2{print $4}') 可用"
log_end

# ---------- 5. C7 专用：设备树 / 内核 defconfig / vendor 生成 ----------
if [ "$DEVICE" = "c7ltechn" ]; then
  log_group "C7 设备树检查"
  SYNCED_DT="$SRC_ROOT/device/samsung/c7ltechn"
  # 设备树：优先 repo sync（manifest），缺则从 CI checkout 复制兜底。
  ensure_file "$SYNCED_DT/proprietary-files.txt" "设备树 proprietary-files.txt（repo sync 的 self remote 设备树项目常被静默跳过）" \
    "rm -rf '$SYNCED_DT' && mkdir -p '$(dirname "$SYNCED_DT")' && cp -a '$PROJECT_ROOT/device/samsung/c7ltechn' '$SYNCED_DT'"
  log_end

  log_group "C7 内核 defconfig"
  KCFG="$SRC_ROOT/kernel/samsung/msm8953/arch/arm64/configs/c7ltechn_defconfig"
  ensure_file "$KCFG" "c7ltechn_defconfig（lineage-16.0 内核分支不含此 defconfig，需从 CI 仓库安装）" \
    "mkdir -p '$(dirname "$KCFG")' && cp '$PROJECT_ROOT/kernel/c7ltechn_defconfig' '$KCFG'"
  log_end

  log_group "C7 内核补丁（修复 A6 内核 V1 battery 的 SM5705 头文件 bug）"
  KPATCHES="$PROJECT_ROOT/kernel/patches"
  if [ -d "$KPATCHES" ]; then
    for p in "$KPATCHES"/*.patch; do
      [ -f "$p" ] || continue
      if patch -p1 --dry-run -d "$SRC_ROOT/kernel/samsung/msm8953" < "$p" >/dev/null 2>&1; then
        patch -p1 -d "$SRC_ROOT/kernel/samsung/msm8953" < "$p" >/dev/null 2>&1 \
          && echo "::notice::内核补丁已应用: $(basename "$p")" \
          || echo "::warning::内核补丁应用失败: $(basename "$p")"
      else
        echo "::notice::内核补丁已存在或不需要: $(basename "$p")"
      fi
    done
  fi
  log_end

  log_group "C7 vendor 提取"
  EXTRACT_DIR="$SRC_ROOT/.c7extract"
  mkdir -p "$EXTRACT_DIR/system"
  C7_READY=0
  # C7 原厂 blob 优先从 CI 仓库自带（vendor/extract/c7ltechn/system/）复制，
  # 无需 GitHub Releases（PAT 无 Releases 写权限，Release 一直传不上去）。
  REPO_EXTRACT="$PROJECT_ROOT/vendor/extract/c7ltechn/system"
  if [ -d "$REPO_EXTRACT" ] && [ -n "$(ls -A "$REPO_EXTRACT" 2>/dev/null)" ]; then
    cp -a "$REPO_EXTRACT/." "$EXTRACT_DIR/system/"
    C7_READY=1
    echo "::notice::C7 原厂 blob 已从仓库自带复制（$(find "$EXTRACT_DIR/system" -type f | wc -l) 个文件）"
  elif [ -n "${C7_EXTRACT_URL:-}" ] && [ ! -f "$EXTRACT_DIR/system/vendor/etc/fstab.qcom" ]; then
    echo "::group::下载 C7 提取包 ($C7_EXTRACT_URL)"
    PKG="$EXTRACT_DIR/c7extract.zip"
    if curl -fL --retry 3 --retry-delay 5 -o "$PKG" "$C7_EXTRACT_URL"; then
      # 提取包是 zip，内含 c7extract/system.tar.gz（也可能直接含 system/）
      if command -v unzip >/dev/null 2>&1; then
        unzip -o "$PKG" -d "$EXTRACT_DIR" >/dev/null 2>&1
      else
        python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$PKG" "$EXTRACT_DIR"
      fi
      # 解压后定位 system.tar.gz（可能在 c7extract/ 或根）
      SYS_TGZ=""
      for cand in "$EXTRACT_DIR/c7extract/system.tar.gz" "$EXTRACT_DIR/system.tar.gz"; do
        [ -f "$cand" ] && SYS_TGZ="$cand" && break
      done
      if [ -n "$SYS_TGZ" ]; then
        tar xzf "$SYS_TGZ" -C "$EXTRACT_DIR"
        C7_READY=1
        echo "::notice::C7 原厂提取包下载并解压成功（system.tar.gz: $SYS_TGZ）"
      else
        echo "::warning::zip 内未找到 system.tar.gz，可能结构不同："
        find "$EXTRACT_DIR" -maxdepth 2 -name "*.tar.gz" -o -maxdepth 2 -name "vendor" -type d 2>/dev/null | head -5
      fi
    else
      echo "::warning::C7 提取包下载失败（URL: $C7_EXTRACT_URL），回退 j7 blobs 兜底"
    fi
    echo "::endgroup::"
  else
    echo "::warning::仓库无 C7 提取 blob、C7_EXTRACT_URL 未配置，回退 j7 blobs 兜底"
  fi

  # extract-files.sh 依赖 vendor/lineage/build/tools/extract_utils.sh，
  # 该文件由 LineageOS/android_vendor_lineage 提供，LOS16 默认清单的
  # snippets 会拉取，缺则直接从 GitHub 拉取对应仓库。
  HELPER="$SRC_ROOT/vendor/lineage/build/tools/extract_utils.sh"
  ensure_file "$HELPER" "vendor/lineage 的 extract_utils.sh（extract-files.sh 依赖）" \
    "mkdir -p '$SRC_ROOT/vendor' && git clone -b lineage-16.0 --depth 1 https://github.com/LineageOS/android_vendor_lineage '$SRC_ROOT/vendor/lineage'"

  # j7 vendor 兜底目录：用于补齐 C7 缺失的 blob（602 个全部可补齐，已演算验证）
  J7_PROP="$SRC_ROOT/vendor/samsung/j7popltespr/proprietary"
  ensure_dir "$J7_PROP" "j7popltespr 的 proprietary blobs（vendor/samsung 兜底来源）" \
    "mkdir -p '$SRC_ROOT/vendor' && git clone -b lineage-16.0 --depth 1 https://github.com/Galaxy-MSM8953/proprietary_vendor_samsung '$SRC_ROOT/vendor/samsung'"

  PROP_LIST="$SYNCED_DT/proprietary-files.txt"
  # 将 j7 blob 兜底填入提取目录：C7 提取包优先，缺的用 j7 的。
  # LOS 的 proprietary-files.txt 语法：
  #   - 每行一个 blob，可带 |sha1 校验后缀（忽略）
  #   - 行首 - 前缀表示"可选"（缺失允许）
  #   - src:dest 形式表示从提取包的 src 复制为 blob 的 dest
  missing_required=0
  missing_optional=0
  while IFS= read -r line; do
    case "$line" in ""|"#"*) continue;; esac
    line="${line%%|*}"
    optional=0
    case "$line" in -*) optional=1; line="${line#-}";; esac
    src="${line%%:*}"
    dest="${line#*:}"
    [ "$src" = "$line" ] && dest="$src"
    src="$(printf '%s' "$src" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    dest="$(printf '%s' "$dest" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$src" ] && continue
    sfile="$EXTRACT_DIR/system/$src"
    jfile="$J7_PROP/$dest"
    if [ -f "$sfile" ]; then
      [ "$C7_READY" = "0" ] && echo "保留 C7 旧缓存: $src"
    elif [ -f "$jfile" ]; then
      mkdir -p "$(dirname "$sfile")"
      cp "$jfile" "$sfile"
      echo "fallback(j7): $src"
    else
      if [ "$optional" -eq 1 ]; then
        echo "::warning::[可选] $src 缺失（允许）"
        missing_optional=$((missing_optional+1))
      else
        echo "::error::[必需] $src 在提取包与 j7 vendor 中均缺失"
        missing_required=$((missing_required+1))
      fi
    fi
  done < "$PROP_LIST"
  echo "j7 兜底填充完成：可选缺失 $missing_optional，必需缺失 $missing_required"
  if [ "$missing_required" -gt 0 ]; then
    echo "::error::存在必需 blob 缺失，无法构建 vendor"
    exit 1
  fi

  # 运行 extract-files.sh 生成 vendor/samsung/c7ltechn。
  # 保险：强制把 setup-makefiles.sh 的 DEVICE 修正为 c7ltechn，
  # 防止设备树仓库里该值被改回 j7 导致 makefile 生成到错误目录。
  if [ -f "$EXTRACT_DIR/system/vendor/etc/fstab.qcom" ] || compgen -G "$EXTRACT_DIR/system/vendor/lib/*.so" >/dev/null; then
    if ! grep -q "DEVICE=c7ltechn" "$SYNCED_DT/setup-makefiles.sh"; then
      sed -i 's/^DEVICE=.*/DEVICE=c7ltechn/' "$SYNCED_DT/setup-makefiles.sh"
      echo "::notice::已自动修正 setup-makefiles.sh 的 DEVICE 为 c7ltechn"
    fi
    if ! grep -q "DEVICE=c7ltechn" "$SYNCED_DT/extract-files.sh"; then
      sed -i 's/^DEVICE=.*/DEVICE=c7ltechn/' "$SYNCED_DT/extract-files.sh"
      echo "::notice::已自动修正 extract-files.sh 的 DEVICE 为 c7ltechn"
    fi
    # 必须在 repo sync 后的设备树目录里跑：extract-files.sh 用相对路径
    # ../../.. 找 $SRC_ROOT/vendor/lineage/build/tools/extract_utils.sh
    ( cd "$SYNCED_DT" && ./extract-files.sh "$EXTRACT_DIR" )

    # 生成结果自愈检查：vendor makefile 应已生成在 vendor/samsung/c7ltechn/
    C7_MAKEFILE="$SRC_ROOT/vendor/samsung/c7ltechn/Android.mk"
    if [ ! -f "$C7_MAKEFILE" ]; then
      echo "::error::vendor makefile 未生成：$C7_MAKEFILE"
      echo "::error::extract-files.sh 已运行，请检查其输出"
      ls -la "$SRC_ROOT/vendor/samsung/" 2>/dev/null || true
      exit 1
    fi
    # 校验 makefile 内容确实面向 c7ltechn（防 DEVICE 变量又改错）
    if grep -q "c7ltechn" "$C7_MAKEFILE"; then
      echo "::notice::vendor makefile 已就绪: $C7_MAKEFILE"
    else
      echo "::error::vendor makefile 内容不含 c7ltechn，疑似 DEVICE 变量仍指向错误设备"
      exit 1
    fi
  else
    echo "::error::C7 vendor 生成失败：提取目录无任何 blob 可用"
    echo "::error::请检查 C7_EXTRACT_URL 是否能下载，或 device/samsung/c7ltechn/proprietary-files.txt 内容"
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
# mka 失败时自动重试一次（AOSP 编译偶发 OOM/资源竞争，重跑常能过）。
# 重试仍失败才报错退出。
log_group "mka $TARGET -j$BUILD_JOBS"

# 资源自检：磁盘不够会中途炸，先量化
DISK_AVAIL="$(df -Pk "$SRC_ROOT" | awk 'NR==2{print $4}')"   # KB
MEM_TOTAL="$(awk '/MemTotal/{print $2}' /proc/meminfo)"      # KB
echo "磁盘可用: $((DISK_AVAIL/1048576)) GB | 内存: $((MEM_TOTAL/1048576)) GB | BUILD_JOBS=$BUILD_JOBS"
if [ "$DISK_AVAIL" -lt 5000000 ]; then
  echo "::error::磁盘可用空间不足 5GB（仅 $((DISK_AVAIL/1048576)) GB），编译将失败"
  echo "::error::AOSP 全量需要 ~60GB：源码 38G + out 22G。请用更大磁盘的 runner"
  exit 1
fi

status=1
# 后台资源监控：记录编译期间内存/swap/进程数 + 编译进度，失败后用于诊断
MON_LOG="$SRC_ROOT/.buildmon.log"
: > "$MON_LOG"
(
  while true; do
    PROG="$(tail -c 200000 "$SRC_ROOT/build.log" 2>/dev/null | grep -aoE '\[ *[0-9]+% +[0-9]+/[0-9]+\]' | tail -1)"
    printf '%s mem=%s swap=%s procs=%s load=%s prog=%s\n' \
      "$(date -u +%H:%M:%S)" \
      "$(free -m | awk '/Mem:/{printf "%d/%d", $7, $2}')" \
      "$(free -m | awk '/Swap:/{printf "%d", $3}')" \
      "$(ps -e --no-headers | wc -l)" \
      "$(cat /proc/loadavg | cut -d' ' -f1-3)" \
      "${PROG:-none}" \
      >> "$MON_LOG"
    sleep 20
  done
) &
MON_PID=$!

# 信号/错误捕获：即使 mka 被信号杀，也把状态写到文件（诊断用）
trap 'echo "TRAP: build.sh received signal at $(date -u +%H:%M:%S), status=$status" >> "$SRC_ROOT/.buildsig.log" 2>/dev/null || true' EXIT
for attempt in 1 2; do
  echo "==== 构建尝试 $attempt/2（mka $TARGET -j$BUILD_JOBS）===="
  set +e
  mka "$TARGET" -j"$BUILD_JOBS" 2>&1 | tee "$SRC_ROOT/build.log"
  status=${PIPESTATUS[0]}
  set -e
  if [ "$status" -eq 0 ]; then
    break
  fi
  echo "::warning::mka 失败 (exit $status)，第 $attempt 次"
  if [ "$attempt" -eq 1 ]; then
    echo "::warning::首次失败原因（build.log 末尾）："
    tail -n 25 "$SRC_ROOT/build.log" || true
    echo "::warning::30 秒后自动重试一次（偶发 OOM/资源竞争）..."
    sleep 30
  fi
done
kill "$MON_PID" 2>/dev/null || true
log_end

if [ "$status" -ne 0 ]; then
  echo "::error::构建失败 (exit $status，重试后仍失败)，build.log 末尾："
  tail -n 40 "$SRC_ROOT/build.log" || true
  echo "::error::==== 资源监控日志（编译期间内存/swap/进程数）===="
  cat "$MON_LOG" 2>/dev/null | tail -30 || true
  echo "::error::==== 磁盘状况 ===="
  df -h "$SRC_ROOT" 2>/dev/null | tail -1
  exit "$status"
fi

# ---------- 9. 产物 ----------
echo "=== 构建产物 ==="
ls -lh out/target/product/"$DEVICE"/lineage_*.zip 2>/dev/null || true
echo "=== 完成 ==="
