#!/usr/bin/env python3
"""
把 mido MIUI 10 (Android 7.1) system 合并进 C7 (c7ltechn) LOS 14.1 base。

规则（XDA 设备移植法，硬件 HAL 留 C7 侧）：
  app/priv-app/framework/media/fonts  -> 全部用 MIUI 的
  lib/lib64/bin/xbin/vendor/usr       -> 硬件相关，以 C7 base 为主；
                                          MIUI 独有的库补充进去；同名冲突用 base
  etc                                  -> 以 base 为主（qcom/samsung 配置），
                                          MIUI 独有文件补充
  build.prop                           -> 以 MIUI 为主，注入 C7 设备属性
  boot.img/logo.img 等非 system 部件    -> 沿用 base 原样（selinux 后续调试）
用法:
  miui10_port.py --base <los.zip> --port <miui.zip> --out <out.zip> [--workspace dir]
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

HARDWARE_DIRS = ("bin", "lib", "lib64", "vendor", "usr", "xbin")
# etc 里这些子目录/前缀视为硬件关键，强制 base 优先
ETC_HARDWARE_PREFIX = ("audio", "camera", "wifi", "qcom", "firmware", "bluetooth",
                       "permissions", "init", "sysconfig", "drm", "input", "media_codecs")

ZIP_OUTPUT_IGNORE = ("META-INF", "boot.img", "recovery.img", "dtb.img", "dt.img",
                     "file_contexts", "otacert", "compatibility.zip")


def unzip(zp, dst):
    with zipfile.ZipFile(zp) as z:
        z.extractall(dst)
    return dst


def list_system_dirs(root):
    sys_root = os.path.join(root, "system")
    if not os.path.isdir(sys_root):
        return None
    return sys_root


def merge_dirs(base_sys, port_sys, out_sys):
    """copy port tree, base overrides hardware-critical, then port fills gaps"""
    # 1. 先铺 base 的全部（硬件保底）
    for ent in sorted(os.listdir(base_sys)):
        _copy(os.path.join(base_sys, ent), os.path.join(out_sys, ent))
    # 2. MIUI 补齐：app/priv-app/framework/media/fonts/overlay 强制用 MIUI
    for ent in sorted(os.listdir(port_sys)):
        if ent in ("lib", "lib64", "bin", "vendor", "usr", "xbin"):
            # 同名文件/库：保留 base；仅 MIUI 有的补充
            _merge_libs(os.path.join(port_sys, ent), os.path.join(out_sys, ent))
        else:
            # 目录级别：用 MIUI 整树覆盖（app 等），不存在则复制
            if ent == "etc":
                _merge_etc(os.path.join(port_sys, ent), os.path.join(out_sys, ent))
            else:
                src = os.path.join(port_sys, ent)
                dst = os.path.join(out_sys, ent)
                if os.path.isdir(src):
                    if os.path.isdir(dst):
                        shutil.rmtree(dst)
                    elif os.path.exists(dst):
                        os.remove(dst)
                    shutil.copytree(src, dst, symlinks=True,
                                    ignore=shutil.ignore_patterns(".git", "*~"))
                elif os.path.isfile(src):
                    os.makedirs(out_sys, exist_ok=True)
                    if os.path.isdir(dst):
                        shutil.rmtree(dst)
                    shutil.copy2(src, dst)


def _copy(src, dst):
    if os.path.isdir(src):
        if os.path.exists(dst):
            shutil.rmtree(dst)
        shutil.copytree(src, dst, symlinks=True,
                        ignore=shutil.ignore_patterns(".git", "*~"))
    else:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)


def _merge_libs(port_dir, out_dir):
    """lib/bin/vendor：仅补充 MIUI 独有条目"""
    if not os.path.isdir(port_dir):
        return
    for r, _, fs in os.walk(port_dir):
        rel = os.path.relpath(r, port_dir)
        out_r = out_dir if rel == "." else os.path.join(out_dir, rel)
        for f in fs:
            p = os.path.join(r, f)
            op = os.path.join(out_r, f)
            if os.path.exists(op):
                continue  # base 优先
            os.makedirs(out_r, exist_ok=True)
            shutil.copy2(p, op)
    # 保留 base 中 MIUI 没有的（_merge_libs 只增不删，天然成立）


def _merge_etc(port_etc, out_etc):
    """etc：base 优先硬件相关；MIUI 独有补充"""
    for r, _, fs in os.walk(port_etc):
        rel = os.path.relpath(r, port_etc)
        out_r = out_etc if rel == "." else os.path.join(out_etc, rel)
        for f in fs:
            p = os.path.join(r, f)
            op = os.path.join(out_r, f)
            rel_path = os.path.join(rel, f).lstrip("./")
            if os.path.exists(op):
                if rel_path.startswith(ETC_HARDWARE_PREFIX):
                    continue  # 硬件配置 base 优先
                os.remove(op)  # 通用配置 MIUI 覆盖
            os.makedirs(out_r, exist_ok=True)
            shutil.copy2(p, op)


def merge_build_prop(base_sys, port_sys, out_sys):
    port_bp = os.path.join(port_sys, "build.prop")
    out_bp = os.path.join(out_sys, "build.prop")
    if not os.path.exists(port_bp):
        shutil.copy2(os.path.join(base_sys, "build.prop"), out_bp)
        return
    props = []
    with open(port_bp, "r", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if line.startswith("ro.build.fingerprint=") or line.startswith("ro.build.description="):
                continue
            props.append(line)
    # 注入 C7 身份（来自 lineage.mk / mido 同代参数）
    props.append("ro.product.model=SM-C7000")
    props.append("ro.product.brand=samsung")
    props.append("ro.product.name=c7ltezc")
    props.append("ro.product.device=c7ltechn")
    props.append("ro.product.board=msm8953")
    props.append("ro.product.manufacturer=samsung")
    props.append("ro.product.locale=en-US")
    props.append("ro.build.flavor=lineage_c7ltechn-userdebug")
    props.append("ro.build.type=userdebug")
    props.append("ro.hardware=msm8953")
    props.append("ro.miui.version.code_time=")
    props.append("ro.boot.hardware=msm8953")
    props.append(
        "ro.build.fingerprint=samsung/c7ltezc/c7ltechn:7.0/NRD90M/C7000ZCU3BRG1:user/release-keys")
    props.append("ro.build.description=c7ltechn-user 7.0 NRD90M C7000ZCU3BRG1 release-keys")
    with open(out_bp, "w") as fh:
        fh.write("\n".join(props) + "\n")


def build_updater(out_zip_dir):
    meta = os.path.join(out_zip_dir, "META-INF/com/google/android")
    os.makedirs(meta, exist_ok=True)
    # 最小 updater-script：挂载 /system 后直接解压（bacon 包同结构）
    script = (
        "ui_print(\"C7 (SM-C7000) MIUI 10\");\n"
        "ui_print(\"Installing /system...\");\n"
        "mount(\"ext4\", \"EMMC\", \"/dev/block/platform/13540000.dwmmc0/by-name/system\", \"/system\");\n"
        "package_extract_dir(\"system\", \"/system\");\n"
        "unmount(\"/system\");\n"
        "ui_print(\"Done.\");\n"
    )
    with open(os.path.join(meta, "updater-script"), "w") as fh:
        fh.write(script)


def repackage(base_zip, out_zip_dir, out_zip):
    # boot/recovery 沿用 base
    tmp = os.path.join(out_zip_dir, "_base_images")
    os.makedirs(tmp, exist_ok=True)
    with zipfile.ZipFile(base_zip) as bz:
        for name in bz.namelist():
            if name in ("boot.img", "recovery.img", "dtb.img", "dt.img"):
                bz.extract(name, tmp)
    for f in os.listdir(tmp):
        shutil.copy2(os.path.join(tmp, f), os.path.join(out_zip_dir, f))
    shutil.rmtree(tmp)
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(out_zip_dir):
            for f in files:
                p = os.path.join(root, f)
                arc = os.path.relpath(p, out_zip_dir)
                z.write(p, arc)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--port", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--workspace")
    args = ap.parse_args()

    for f in (args.base, args.port):
        if not os.path.exists(f):
            sys.exit(f"缺少输入: {f}")

    work = args.workspace or tempfile.mkdtemp(prefix="miui_port_")
    base_dir = os.path.join(work, "base")
    port_dir = os.path.join(work, "port")
    out_dir = os.path.join(work, "out")
    print(f"[*] 解包 base...")
    unzip(args.base, base_dir)
    print(f"[*] 解包 MIUI...")
    unzip(args.port, port_dir)

    base_sys = list_system_dirs(base_dir)
    port_sys = list_system_dirs(port_dir)
    if not base_sys:
        sys.exit("base 无 system/ 目录")
    if not port_sys:
        print("[!] MIUI 底包无 system/（可能是 dat 镜像包），跳过 system 合并")
    out_sys = os.path.join(out_dir, "system")
    os.makedirs(out_sys, exist_ok=True)

    if port_sys:
        print(f"[*] 合并 system...")
        merge_dirs(base_sys, port_sys, out_sys)
        print(f"[*] 生成 build.prop...")
        merge_build_prop(base_sys, port_sys, out_sys)

    print(f"[*] 生成 updater-script...")
    build_updater(out_dir)
    print(f"[*] 打包 {args.out}...")
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    repackage(args.base, out_dir, args.out)
    size_mb = os.path.getsize(args.out) / 1048576
    print(f"[OK] 输出: {args.out} ({size_mb:.0f} MB)")
    if args.workspace is None:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
