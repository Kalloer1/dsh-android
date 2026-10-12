#!/usr/bin/env python3
# dsh-android：给 stage/种子树里的 dsh 依赖打 Android 补丁（幂等，可重复跑）。
# 覆盖两个已实锤死点（docs/ANDROID-NATIVE-RISKS.md）：
#  A) node-addon-system/lib/flock.js：platform==='android' 抛 ERR_FLOCK_UNSUPPORTED_PLATFORM
#     → 放行 android；resolve 失败时优先加载随包 bin-android/system.node（NDK 自编 bionic 版），
#       加载不到则退化为进程内 no-op 锁（本 APK 保证 dsh web 单实例）。
#  B) dsh-session-persistence-jsonl/lib/index.js：两处 link(2)（:2034 staged 发布、
#     :3142 materializePosix）SELinux 拒 EPERM/EACCES 且无兜底 → 加 copy+unlink 降级。
# 用法：patch-android-persistence.py <root>   （递归找 node_modules 里的目标文件）
import sys, os, glob

TAG = "dsh-android-patch"

FLOCK_GUARD_OLD = "if (platform !== 'linux' && platform !== 'darwin') {"
FLOCK_GUARD_NEW = "if (platform !== 'linux' && platform !== 'darwin' && platform !== 'android') {"
FLOCK_RESOLVE_OLD = "    const manifest = require.resolve(`@deepseek-ai/node-addon-system-${platform}-${arch}/package.json`);"
FLOCK_RESOLVE_NEW = """    let manifest;
    try {
        manifest = require.resolve(`@deepseek-ai/node-addon-system-${platform}-${arch}/package.json`);
    } catch (e) {
        if (platform !== "android") throw e;
        /* dsh-android-patch: bionic build shipped beside this package, else single-instance no-op lock */
        try { binding = require("../bin-android/system.node"); }
        catch (loadErr) { binding = { tryLock: (fd, cb) => { queueMicrotask(() => cb(0)); } }; }
        return binding;
    }"""

SPJ_IMPORT_OLD = 'import { link, lstat, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";'
SPJ_HELPER = (SPJ_IMPORT_OLD +
    "\n/* dsh-android-patch */ function isLinkDenied(error) {"
    "\n\tconst code = error?.code;"
    "\n\treturn code === \"EPERM\" || code === \"EACCES\" || code === \"EXDEV\" || code === \"ENOTSUP\" || code === \"EOPNOTSUPP\" || code === \"ENOSYS\";"
    "\n}")

SPJ_PUBLISH_OLD = """	await internals.fs.link(staged, currentPath);
	} catch (error) {
		/* v8 ignore else -- a non-collision filesystem error propagates unchanged. */
		if (isEEXIST(error)) return false;
		/* v8 ignore next -- the filesystem error is already complete. */
		throw error;
	}"""
SPJ_PUBLISH_NEW = """	await internals.fs.link(staged, currentPath);
	} catch (error) {
		if (isEEXIST(error)) return false;
		/* dsh-android-patch: SELinux app-data_file denies link(2); degrade to copy. */
		if (isLinkDenied(error)) {
			await copyFile(staged, currentPath);
			await rm(staged, { force: true });
		} else {
			throw error;
		}
	}"""

SPJ_MAT_OLD = """			await link(tmp, finalPath);
			linked = true;
		} finally {
			/* v8 ignore next -- link failure is the TOCTOU/IO race guarded above; not reachable in test */
			if (!linked) await rm(tmp, { force: true });
		}"""
SPJ_MAT_NEW = """			await link(tmp, finalPath);
			linked = true;
		} catch (error) {
			/* dsh-android-patch: link(2) denied on app-private dirs; copy degrades safely (single writer). */
			if (!isLinkDenied(error)) throw error;
			await copyFile(tmp, finalPath);
			linked = true;
		} finally {
			if (!linked) await rm(tmp, { force: true });
		}"""

def apply(path, repls):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if TAG in text:
        print(f"[skip] already patched: {path}")
        return True
    ok = True
    for old, new in repls:
        n = text.count(old)
        if n != 1:
            print(f"[FAIL] {path}: anchor count={n}: {old[:60]!r}")
            ok = False
        else:
            text = text.replace(old, new)
    if ok:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        print(f"[patched] {path}")
    return ok

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    targets = []
    for pat in ("*/node_modules/@deepseek-ai/node-addon-system/lib/flock.js",):
        targets += [(p, [(FLOCK_GUARD_OLD, FLOCK_GUARD_NEW), (FLOCK_RESOLVE_OLD, FLOCK_RESOLVE_NEW)])
                    for p in glob.glob(f"{root}/**/node-addon-system/lib/flock.js", recursive=True)]
    targets += [(p, [(SPJ_IMPORT_OLD, SPJ_HELPER), (SPJ_PUBLISH_OLD, SPJ_PUBLISH_NEW), (SPJ_MAT_OLD, SPJ_MAT_NEW)])
                for p in glob.glob(f"{root}/**/dsh-session-persistence-jsonl/lib/index.js", recursive=True)]
    if not targets:
        print(f"[FAIL] no target files under {root}")
        return 2
    # import 行替换里要带上 copyFile
    spjfix = []
    for p, repls in targets:
        if "dsh-session-persistence-jsonl" in p:
            repls = [(a, b.replace(SPJ_IMPORT_OLD, 'import { copyFile, link, lstat, mkdir, mkdtemp, open, readFile, readdir, realpath, rm, stat, truncate } from "node:fs/promises";\n/* dsh-android-patch */ function isLinkDenied(error) {\n\tconst code = error?.code;\n\treturn code === "EPERM" || code === "EACCES" || code === "EXDEV" || code === "ENOTSUP" || code === "EOPNOTSUPP" || code === "ENOSYS";\n}')) for a, b in repls]
            spjfix.append((p, repls))
        else:
            spjfix.append((p, repls))
    bad = 0
    for p, repls in spjfix:
        # flock.js 的 binding 声明在其后，替换里的 return binding 早于赋值——loader 用闭包变量，合法
        if not apply(p, repls):
            bad += 1
    print(f"[done] {len(spjfix)-bad}/{len(spjfix)} ok")
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
