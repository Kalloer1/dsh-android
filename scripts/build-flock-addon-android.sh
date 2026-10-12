#!/usr/bin/env bash
# 交叉编译 dsh flock addon 的 Android(bionic) 版 system.node。
# 背景：@deepseek-ai/node-addon-system 只发 glibc/musl prebuilt；Termux 是 bionic，
# 官方 loader 对 android 分支直接抛 ERR_FLOCK_UNSUPPORTED_PLATFORM（loader 补丁由
# inject 阶段做，见文末）。源码是纯 Node-API（NAPI_MODULE_INIT，无 v8），NDK 可直编。
# CI 里跑（需 $ANDROID_NDK_HOME 与网）；产物放 stage 的 linux-arm64 平台包 bin/ 下，
# 配 loader 小补丁让 android 走 system.node。
set -euo pipefail
log(){ echo "[flock-android] $*"; }

ARCH="${ARCH:-aarch64}"
NODE_VER="${NODE_VER:-26.4.0}"                    # 与 bootstrap 里打种的 nodejs 版本一致
STAGE="${STAGE:?需要 stage 目录（seed 脚本的工作树）}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$REPO_ROOT/build/flock-$ARCH}"
API="${API:-24}"

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
[[ -x "$TOOLCHAIN/clang" ]] || { log "错误：找不到 NDK clang（ANDROID_NDK_HOME）"; exit 1; }

mkdir -p "$WORK"
if [[ ! -s "$WORK/node-headers.tar.gz" ]]; then
    log "下载 node v$NODE_VER headers"
    curl -fsSL --retry 3 -o "$WORK/node-headers.tar.gz" \
        "https://nodejs.org/dist/v$NODE_VER/node-v$NODE_VER-headers.tar.gz"
fi
tar xzf "$WORK/node-headers.tar.gz" -C "$WORK"
INC="$WORK/node-v$NODE_VER/include/node"
[[ -f "$INC/node_api.h" ]] || { log "错误：headers 解包后找不到 $INC/node_api.h"; exit 1; }

SRC="$WORK/flock-src"
rm -rf "$SRC"; mkdir -p "$SRC"
# addon 包在 npm 树里的位置不固定（常嵌在 @deepseek-ai/dsh/node_modules 下），find 定位
ADDON_PKG="$(find "$STAGE" -type d -path "*/@deepseek-ai/node-addon-system" 2>/dev/null | head -1)"
[[ -n "$ADDON_PKG" && -d "$ADDON_PKG/src" ]] || { log "错误：stage 里找不到带 src 的 addon 包（检查 DSH 注入步）"; exit 1; }
cp "$ADDON_PKG/src/flock.c" "$SRC/"

log "NDK clang 交叉编译 android-$ARCH system.node (API $API)"
"$TOOLCHAIN/clang" --target="$ARCH-linux-android$API" -shared -fPIC -O2 \
    -DNAPI_VERSION=8 -I"$INC" \
    -o "$WORK/system.node" "$SRC/flock.c"
file "$WORK/system.node"

DESTROOT="$STAGE"
placed=0
while IFS= read -r pkgjson; do
    d=$(dirname "$pkgjson")/bin-android
    mkdir -p "$d"
    cp "$WORK/system.node" "$d/system.node"
    chmod 755 "$d/system.node"
    placed=$((placed+1))
done < <(find "$WORK" -path "*/@deepseek-ai/node-addon-system/package.json" 2>/dev/null; find "$STAGE" -path "*/@deepseek-ai/node-addon-system/package.json" 2>/dev/null)
log "system.node 已放置 $placed 处（loader 补丁由 patch-android-persistence.py 在 e3 步完成）"
[[ $placed -ge 1 ]] || { log "错误：一个 addon 包都没找到"; exit 1; }
