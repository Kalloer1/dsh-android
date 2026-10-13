#!/usr/bin/env bash
# dsh-android: 把 NDK 交叉编译的 require_builtin.node（napi-v9）注入两棵依赖树。
# loader 的 local-build 源会在主包目录 build/<backend>/<abi>-<platform>-<arch>/ 下
# 直接捡现成二进制（见 node-addon-native-custom-loader/lib/index.js:537-560），
# 因此无需伪造 optional 平台包。
# 用法：inject-require-builtin.sh <stage_root> <out_dir>
#   stage_root = build/seed-<arch>（含 stage/ 与 dshseed/）；arch 由目录名推断
set -euo pipefail
ROOT="${1:?用法: inject-require-builtin.sh <seed-stage-root> <addon-out-root>}"
SRC="${2:?缺少 NDK 产物根目录（含 android-arm64/android-x64）}"
log(){ echo "[inject-rb] $*"; }

case "$ROOT" in
  *aarch64*|*arm64*) PLAT_ARCH=arm64; ABI_DIR=napi-v9-android-arm64 ;;
  *x86_64*)          PLAT_ARCH=x64;   ABI_DIR=napi-v9-android-x64 ;;
  *) log "错误：无法从 $ROOT 推断架构"; exit 1 ;;
esac
NODE="$SRC/android-$PLAT_ARCH/require_builtin.node"
[[ -f "$NODE" ]] || { log "错误：找不到 $NODE"; exit 1; }

count=0
while IFS= read -r pkg; do
    d="$(dirname "$pkg")/build/napi/$ABI_DIR"
    mkdir -p "$d"
    cp -f "$NODE" "$d/require_builtin.node"
    chmod 755 "$d/require_builtin.node"
    count=$((count+1))
done < <(find "$ROOT" -path "*/node-addon-require-builtin/package.json" 2>/dev/null)

log "注入 $count 处（$ABI_DIR）"
[[ $count -ge 1 ]] || { log "错误：一棵 require-builtin 包树都没找到"; exit 1; }
