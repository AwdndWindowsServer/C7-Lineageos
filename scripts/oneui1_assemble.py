#!/usr/bin/env python3
"""
把 a6plte (Galaxy A6+) One UI 1 (Android 9) system 与 C7 (c7ltechn) Android 9
boot.img 组装成可刷 zip。

C7 用 PRODUCT_VENDOR_MOVE_ENABLED（vendor 并入 system），boot.img 是 LOS 16.0
编译的 AOSP ramdisk，system 为 a6plte One UI 单分区树 → 结构匹配。

用法:
  oneui1_assemble.py --system <oneui_system_dir> --boot <boot.img> \
      [--c7blobs <c7_system_dir>] --out <C7_OneUI1_unsigned.zip>
"""
import argparse
import os
import shutil
import sys
import zipfile

C7_FINGERPRINT = "samsung/c7ltezc/c7ltechn:8.0.0/R16NW/C7000ZCS3CRJ1:user/release-keys"
C7_BUILD_DESC = "c7ltechn-user 8.0.0 R16NW C7000ZCS3CRJ1 release-keys"

# 覆盖 build.prop：把这些属性从 a6plte 换成 C7
C7_PROPS = {
    "ro.product.model": "SM-C7000",
    "ro.product.name": "c7ltezc",
    "ro.product.device": "c7ltechn",
    "ro.product.board": "msm8953",
    "ro.product.manufacturer": "samsung",
    "ro.product.brand": "samsung",
    "ro.build.fingerprint": C7_FINGERPRINT,
    "ro.build.description": C7_BUILD_DESC,
    "ro.boot.hardware": "msm8953",
    "ro.hardware": "msm8953",
}

DROP_PROPS = ("ro.product.model", "ro.product.name", "ro.product.device",
              "ro.product.board", "ro.product.manufacturer", "ro.product.brand",
              "ro.build.fingerprint", "ro.build.description")


def patch_build_prop(sys_dir):
    bp = os.path.join(sys_dir, "build.prop")
    if not os.path.exists(bp):
        return
    kept = []
    with open(bp, "r", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            key = line.split("=", 1)[0].strip()
            if key in DROP_PROPS:
                continue
            if key.startswith("ro.product.locale"):
                continue
            kept.append(line)
    for k, v in C7_PROPS.items():
        kept.append(f"{k}={v}")
    # 调试用：不强求 enforce，先标记（实际首次验证仍以 adb setenforce 0 为准）
    kept.append("ro.debuggable=1")
    kept.append("persist.sys.usb.config=adb")
    with open(bp, "w") as fh:
        fh.write("\n".join(kept) + "\n")


def build_updater(out_dir):
    meta = os.path.join(out_dir, "META-INF/com/google/android")
    os.makedirs(meta, exist_ok=True)
    script = (
        'ui_print("C7 (SM-C7000) One UI 1");\n'
        'ui_print("Installing /system + boot...");\n'
        'mount("ext4", "EMMC", "/dev/block/platform/13540000.dwmmc0/by-name/system", "/system");\n'
        'package_extract_dir("system", "/system");\n'
        'unmount("/system");\n'
        'package_extract_file("boot.img", "/dev/block/platform/13540000.dwmmc0/by-name/boot");\n'
        'ui_print("Done.");\n'
    )
    with open(os.path.join(meta, "updater-script"), "w") as fh:
        fh.write(script)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--system", required=True, help="a6plte One UI system 解包目录")
    ap.add_argument("--boot", required=True, help="C7 Android 9 boot.img")
    ap.add_argument("--c7blobs", help="可选：C7 原机 system 目录，覆盖 a6plte 同名 blob")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if not os.path.isdir(os.path.join(args.system, "app")):
        ap.error(f"{args.system} 不是有效的 system 树（缺 app/）")
    out_dir = args.out + ".d"
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(out_dir, exist_ok=True)

    print("[*] 复制 One UI system ...")
    shutil.copytree(args.system, os.path.join(out_dir, "system"), symlinks=True,
                    ignore=shutil.ignore_patterns(".git", "*~", "lost+found"))

    if args.c7blobs and os.path.isdir(args.c7blobs):
        print("[*] 覆盖 C7 原机 blob ...")
        for ent in os.listdir(args.c7blobs):
            src = os.path.join(args.c7blobs, ent)
            dst = os.path.join(out_dir, "system", ent)
            if os.path.isdir(src):
                if os.path.isdir(dst):
                    shutil.rmtree(dst)
                elif os.path.exists(dst):
                    os.remove(dst)
                shutil.copytree(src, dst, symlinks=True,
                                ignore=shutil.ignore_patterns(".git", "*~"))
            else:
                if os.path.isdir(dst):
                    shutil.rmtree(dst)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)

    print("[*] 打 build.prop (C7 身份) ...")
    patch_build_prop(os.path.join(out_dir, "system"))

    print("[*] updater-script ...")
    build_updater(out_dir)

    print("[*] boot.img ...")
    shutil.copy2(args.boot, os.path.join(out_dir, "boot.img"))

    print(f"[*] 打包 {args.out} ...")
    with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(out_dir):
            for f in files:
                p = os.path.join(root, f)
                z.write(p, os.path.relpath(p, out_dir))
    shutil.rmtree(out_dir, ignore_errors=True)
    print(f"[OK] 输出: {args.out} ({os.path.getsize(args.out)/1048576:.0f} MB)")


if __name__ == "__main__":
    main()
