#!/usr/bin/env bash
# 注意：不能用 set -u。Android 9 的 build/envsetup.sh 在 bash 4.4+ 的
# nounset 模式下会因空数组报 "unbound variable"（envsetup.sh:1702 _xarray）。
set -eo pipefail

LOS_BRANCH="${LOS_BRANCH:-lineage-16.0}"
DEVICE="${DEVICE:-j7popltespr}"
MANIFEST="${MANIFEST:-manifest/j7popltespr.xml}"
SYNC_JOBS="${SYNC_JOBS:-4}"
BUILD_JOBS="${BUILD_JOBS:-2}"
USE_CCACHE="${USE_CCACHE:-0}"
SRC_ROOT="${SRC_ROOT:-$PWD/android}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

git config --global user.name  "${USER_NAME:-C7 CI}"
git config --global user.email "${USER_MAIL:-ci@localhost}"

# Android 9 需要 OpenJDK 8
JAVA8="$(ls -d /usr/lib/jvm/java-8-openjdk-* 2>/dev/null | head -n1 || true)"
if [ -n "$JAVA8" ]; then
  sudo update-alternatives --set java "$JAVA8/bin/java" 2>/dev/null || true
  export JAVA_HOME="$JAVA8"
  # 直接前置 PATH，确保 `java` 解析到 8（update-alternatives 在 runner 上可能不生效）
  export PATH="$JAVA8/bin:$PATH"
else
  echo "::warning::OpenJDK 8 not found in /usr/lib/jvm"
fi
java -version 2>&1 | head -n1

if [ ! -x /usr/local/bin/repo ]; then
  sudo curl -sSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo
  sudo chmod a+x /usr/local/bin/repo
fi

mkdir -p "$SRC_ROOT"
cd "$SRC_ROOT"

if [ ! -d .repo ]; then
  repo init -u https://github.com/LineageOS/android.git -b "$LOS_BRANCH"
fi

mkdir -p .repo/local_manifests
cp "$PROJECT_ROOT/$MANIFEST" .repo/local_manifests/device.xml

# 网络不稳时重试 sync，最多 3 次
for attempt in 1 2 3; do
  if repo sync -j"$SYNC_JOBS" -c --force-sync --no-clone-bundle --no-tags; then
    break
  fi
  echo "::warning::repo sync failed (attempt $attempt/3), retrying..."
  [ "$attempt" -eq 3 ] && { echo "::error::repo sync failed"; exit 1; }
done

source build/envsetup.sh
lunch "lineage_${DEVICE}-userdebug"

if [ "$USE_CCACHE" = "1" ]; then
  export USE_CCACHE=1 CCACHE_DIR="$SRC_ROOT/.ccache"
  prebuilts/misc/linux-x86/ccache/ccache -M 20G
fi

set +e
mka bacon -j"$BUILD_JOBS" 2>&1 | tee "$SRC_ROOT/build.log"
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ]; then
  echo "::error::Build failed (exit $status). Tail of build.log:"
  tail -n 40 "$SRC_ROOT/build.log" || true
  exit "$status"
fi

echo "=== Artifacts ==="
ls -lh out/target/product/"$DEVICE"/lineage_*.zip 2>/dev/null || true
