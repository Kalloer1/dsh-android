#!/usr/bin/env python3
"""为缺少 SONAME 软链的 stage 补实体副本。
Linux 上 dpkg-deb --extract 会还原 data.tar 内的 symlink；Windows 上 tar 解不出
symlink（无特权），node 链接的 libsqlite3.so 就丢了。这里扫描 lib/*.so.X.Y 形态，
若无同名去尾 .so 则复制一份实体（体积代价可接受，TermInstaller 端本就不认软链条目）。"""
import os, shutil, sys

def main():
    lib = os.path.join(sys.argv[1], "lib")
    if not os.path.isdir(lib):
        print("no lib dir:", lib); return 0
    names = set(os.listdir(lib))
    added = 0
    for f in list(names):
        if ".so" not in f or f.endswith(".so"):
            continue
        # 别名层级：libfoo.so.78.3 -> 同时补 libfoo.so.78 与 libfoo.so
        stem = f.split(".so")[0]
        verpart = f.split(".so.", 1)[1] if ".so." in f else ""
        targets = [stem + ".so"]
        if verpart:
            major = verpart.split(".")[0]
            targets.append("%s.so.%s" % (stem, major))
        for base in targets:
            if base == f or base in names or not os.path.isfile(os.path.join(lib, f)):
                continue
            shutil.copyfile(os.path.join(lib, f), os.path.join(lib, base))
            try:
                os.chmod(os.path.join(lib, base), 0o755)
            except Exception:
                pass
            names.add(base); added += 1
            print("added", base)
    print("soname copies:", added)

if __name__ == "__main__":
    main()
