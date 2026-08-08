#!/usr/bin/env bash
#
# 本地构建 C7 (SM-C7000, c7ltechn) MIUI 10 移植包
#
# 阶段：
#   A. 准备：预检（内存/磁盘）、自动建 swap、启动 ubuntu:18.04 编译容器
#   B. 源码：repo init (cm-14.1) + local_manifests + sync（浅克隆）
#   C. 内核：CRLF 归一化 + 已有补丁 dry-run 自适应（不适用的自动跳过）
#   D. 编译：lunch lineage_c7ltechn-userdebug && make bacon → C7 LOS 14.1 base
#   E. 下载 mido MIUI 10（Android 7.1）
#   F. 合并：miui10_port.py 把 MIUI10 system 合入 C7 base → flashable zip
#
# 用法：
#   scripts/miui10_build_local.sh                 # 全流程
#   STAGE=F bash scripts/miui10_build_local.sh    # 只跑到某阶段（A-F）
#
# 环境变量：
#   SRC_ROOT   源码目录（默认 $PWD/android-miui10）
#   BUILD_JOBS make 并行数（默认 1，小内存保险）
#   MIUI_URL   mido MIUI 10 卡刷包直链（默认自动从 xiaomifirmwareupdater 抓）
#   CONTAINER  编译容器名（默认 miui10-build）
set -eo pipefail

SRC_ROOT="${SRC_ROOT:-$PWD/android-miui10}"
DEVICE="c7ltechn"
LOS_BRANCH="cm-14.1"
KERNEL_BRANCH="cm-14.1-c7"
MANIFEST="manifest/c7ltechn-miui10.xml"
BUILD_JOBS="${BUILD_JOBS:-1}"
MIUI_URL="${MIUI_URL:-}"
CONTAINER="${CONTAINER:-miui10-build}"
DOCKER_IMG="ubuntu:18.04"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SRC_ROOT DEVICE

info()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; exit 1; }

# docker 容器内执行
dex() { docker exec -i "$CONTAINER" bash -c "$1"; }

# ---------- A. 预检 / swap / 容器 ----------
stage_a() {
  info "阶段 A：预检 + swap + 编译容器"
  [ "$(nproc)" -ge 1 ]
  local mem_gb disk_gb
  mem_gb="$(awk '/MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)"
  disk_gb="$(df -Pk "$PWD" | awk 'NR==2{printf "%.1f", $4/1048576}')"
  info "内存 ${mem_gb}G / CPU $(nproc)核 / 磁盘可用 ${disk_gb}G"
  awk -v d="$disk_gb" 'BEGIN{ if (d<50) print "  警告：磁盘 <50G，LOS14.1 全量需 ~55G，可能紧张" }'

  # 自动建 swap（内存 <8G 且无 swap）
  if [ "$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)" -lt 8 ] && ! swapon --show | grep -q .; then
    if [ ! -f /swapfile-miui10 ]; then
      info "内存不足 8G 且无 swap，创建 8G swapfile（/swapfile-miui10）..."
      fallocate -l 8G /swapfile-miui10 || dd if=/dev/zero of=/swapfile-miui10 bs=1M count=8192
      chmod 600 /swapfile-miui10
      mkswap /swapfile-miui10 >/dev/null
    fi
    swapon /swapfile-miui10 && ok "swap 已启用（8G）"
  fi

  # 编译容器（ubuntu:18.04，7.1 构建标准环境：自带 python2/OpenJDK8）
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    info "拉取并启动编译容器 $DOCKER_IMG"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CONTAINER" -v "$SRC_ROOT:/src" -w /src "$DOCKER_IMG" sleep infinity >/dev/null
  fi
  if ! dex "test -x /usr/bin/bison && test -x /usr/bin/python3"; then
    info "容器内安装 Android 7.1 构建依赖（首次较慢）..."
    dex "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      git-core gnupg flex bison gperf build-essential zip curl unzip \
      zlib1g-dev gcc-multilib g++-multilib libc6-dev-i386 \
      lib32ncurses5-dev x11proto-core-dev libx11-dev lib32z1-dev \
      libgl1-mesa-dev libxml2-utils xsltproc fontconfig \
      openjdk-8-jdk python python3 ccache 2>&1 | tail -2"
  fi
  dex "git config --global user.email 'build@localhost' && git config --global user.name 'C7 MIUI10 build'"
  ok "容器就绪"
}

# ---------- B. repo init / sync ----------
stage_b() {
  info "阶段 B：repo init (cm-14.1) + sync"
  mkdir -p "$SRC_ROOT"
  dex "test -x /usr/local/bin/repo || { curl -sSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo && chmod +x /usr/local/bin/repo; }"
  if [ ! -f "$SRC_ROOT/.repo/manifest.xml" ]; then
    rm -rf "$SRC_ROOT/.repo"
    # repo 自身源码从清华镜像拉（gerrit.googlesource.com 国内不通）
    dex "repo init -u https://github.com/LineageOS/android.git -b $LOS_BRANCH --depth 1 \
      --repo-url=https://mirrors.tuna.tsinghua.edu.cn/git/git-repo/"
  fi
  mkdir -p "$SRC_ROOT/.repo/local_manifests"
  cp "$PROJECT_ROOT/$MANIFEST" "$SRC_ROOT/.repo/local_manifests/device.xml"
  for attempt in 1 2 3; do
    info "repo sync（第 $attempt/3 次）..."
    if dex "repo sync -j4 -c --force-sync --no-clone-bundle --no-tags"; then break; fi
    [ "$attempt" -eq 3 ] && die "repo sync 多次失败"
  done
  # 兜底：hardware/samsung（cm-14.1 官方 manifest 通常已含，缺则补）
  dex "test -d hardware/samsung || git clone -b $LOS_BRANCH --depth 1 https://github.com/LineageOS/android_hardware_samsung hardware/samsung || true"
  # 关键文件自检
  dex "test -f device/samsung/c7ltechn/device.mk" || die "设备树缺失：device/samsung/c7ltechn"
  dex "test -f vendor/samsung/c7ltechn/Android.mk" || die "vendor 缺失：vendor/samsung/c7ltechn"
  ok "源码就绪"
}

# ---------- C. 内核准备 ----------
stage_c() {
  info "阶段 C：内核 CRLF 归一化 + 补丁自适应"
  # CRLF → LF（Samsung 原始导出文件）
  dex "python3 - /src/kernel/samsung/msm8953 <<'PY'
import os,sys
root=sys.argv[1]; n=0
for r,ds,fs in os.walk(root):
    if os.sep+'.git' in r: continue
    for f in fs:
        if not f.endswith(('.c','.h')): continue
        p=os.path.join(r,f)
        try:
            d=open(p,'rb').read()
            if b'\r\n' in d:
                open(p,'wb').write(d.replace(b'\r\n',b'\n')); n+=1
        except Exception: pass
print('CRLF->LF', n, 'files')
PY" || true
  # 已有补丁 dry-run 自适应（0001-0006 是给 lineage-16.0 内核的，能干净应用才应用）
  local applied=0 skipped=0
  for p in "$PROJECT_ROOT"/kernel/patches/*.patch; do
    [ -f "$p" ] || continue
    if dex "cd /src/kernel/samsung/msm8953 && patch -p1 --dry-run < '$p' >/dev/null 2>&1"; then
      dex "cd /src/kernel/samsung/msm8953 && patch -p1 < '$p' >/dev/null 2>&1"
      info "  应用: $(basename "$p")"; applied=$((applied+1))
    else
      info "  跳过(不适用 cm-14.1 内核): $(basename "$p")"; skipped=$((skipped+1))
    fi
  done
  ok "内核补丁：应用 $applied / 跳过 $skipped"
}

# ---------- D. 编译 base ----------
stage_d() {
  info "阶段 D：编译 C7 LOS 14.1 base (make bacon -j$BUILD_JOBS)"
  dex "test -f build/envsetup.sh" || die "缺少 build/envsetup.sh（源码未就绪）"
  local disk
  disk="$(df -Pk "$SRC_ROOT" | awk 'NR==2{print int($4/1048576)}')"
  [ "$disk" -lt 15 ] && warn "磁盘可用仅 ${disk}G，编译可能爆盘"
  dex "
    source build/envsetup.sh >/dev/null 2>&1
    lunch lineage_${DEVICE}-userdebug >/dev/null 2>&1
    echo '==== 编译开始 $(date -u +%FT%TZ) ====' | tee /src/build-miui10.log
    set -o pipefail
    make bacon -j${BUILD_JOBS} 2>&1 | tee -a /src/build-miui10.log
  "
  local zip
  zip="$(ls "$SRC_ROOT"/out/target/product/$DEVICE/lineage_*.zip 2>/dev/null | head -1 || true)"
  [ -n "$zip" ] || die "base 编译未产出 zip，见 $SRC_ROOT/build-miui10.log"
  ok "base ROM: $zip"
}

# ---------- E. 下载 mido MIUI 10 ----------
stage_e() {
  info "阶段 E：下载 mido MIUI 10"
  mkdir -p "$SRC_ROOT/miui10"
  local z="$SRC_ROOT/miui10/miui10-mido.zip"
  if [ -n "$MIUI_URL" ]; then
    info "使用 MIUI_URL=$MIUI_URL"
    curl -fL --retry 3 -o "$z" "$MIUI_URL" || die "下载失败"
  else
    info "自动探测 mido MIUI 10 稳定版下载链接（xiaomifirmwareupdater）..."
    local page dl
    page="$(curl -fsSL https://xiaomifirmwareupdater.com/miui/mido/stable/ 2>/dev/null || true)"
    dl="$(printf '%s' "$page" | grep -oE 'https://[^"]+V10[^"]+\.zip' | head -1)"
    [ -z "$dl" ] && dl="$(printf '%s' "$page" | grep -oE 'https://[^"]+\.zip' | head -1)"
    [ -z "$dl" ] && die "自动探测失败，请手动设置 MIUI_URL=直链 重跑（STAGE=E）"
    info "  下载: $dl"
    curl -fL --retry 3 -o "$z" "$dl" || die "下载失败"
  fi
  ok "MIUI 10 底包: $z"
}

# ---------- F. 合并 ----------
stage_f() {
  info "阶段 F：合并 MIUI 10 system → C7 base"
  local base
  base="$(ls "$SRC_ROOT"/out/target/product/$DEVICE/lineage_*.zip 2>/dev/null | head -1 || true)"
  [ -n "$base" ] || die "无 base zip（先跑阶段 D）"
  local port="$SRC_ROOT/miui10/miui10-mido.zip"
  [ -f "$port" ] || die "无 MIUI 底包（先跑阶段 E）"
  local out="$SRC_ROOT/C7_MIUI10_unsigned.zip"
  python3 "$PROJECT_ROOT/scripts/miui10_port.py" \
    --base "$base" --port "$port" --out "$out"
  ok "移植包已生成: $out"
  info "提示：selinux 当前沿用 base（LOS enforcing）。测试刷入后若卡开机，先 adb shell setenforce 0 验证"
}

STAGE="${STAGE:-F}"
for s in A B C D E F; do
  stage_$(echo "$s" | tr 'A-Z' 'a-z')
  [ "$s" = "$STAGE" ] && break
done
info "全部完成"
