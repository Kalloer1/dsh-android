#!/usr/bin/env python3
"""zipdir.py <src_dir> <out.zip> —— 以精确相对路径（无 ./ 前缀）打包目录。
Termux 的 TermuxInstaller 对 zip 条目名做精确匹配（"SYMLINKS.txt"、"bin/" 前缀
决定 chmod），bsdtar/GNU tar 生成的 zip 带 "./" 前缀会破坏它。权限位不重要：
TermInstaller 自行对 bin/**、libexec、lib/apt/** 设 0700。"""
import os, sys, zipfile

def main():
    src, out = sys.argv[1], sys.argv[2]
    src = os.path.abspath(src)
    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, dirs, files in os.walk(src):
            for d in dirs:
                p = os.path.join(root, d)
                rel = os.path.relpath(p, src).replace(os.sep, "/") + "/"
                z.write(p, rel)
                n += 1
            for f in files:
                p = os.path.join(root, f)
                rel = os.path.relpath(p, src).replace(os.sep, "/")
                zi = zipfile.ZipInfo.from_file(p, rel)
                zi.compress_type = zipfile.ZIP_DEFLATED
                with open(p, "rb") as fh, z.open(zi, "w") as zo:
                    while True:
                        chunk = fh.read(1 << 20)
                        if not chunk:
                            break
                        zo.write(chunk)
                n += 1
    print("zipped", n, "entries ->", out)

if __name__ == "__main__":
    main()
