#!/usr/bin/env bash
# build-require-builtin-android.sh
# 用 Android NDK 从源码交叉编译 dsh 的 require_builtin.node（napi backend），
# 供 Termux (android-arm64 / android-x64) 使用。需在 Git Bash (MSYS) 下运行。
#
# 用法:  bash build-require-builtin-android.sh [aarch64|x86_64]   （默认 aarch64）
# 产物:  D:/dsh-android/out/android-<arm64|x64>/require_builtin.node
#
# ── abi-tag 结论（已读 naclx loader 源码 D:/dsh-android/naclx/package/lib/index.js）──
# loader 的 buildAbiTag(): napi backend → `napi-v${NAPI_VERSION}`，
#   其中 JS 侧常量 NAPI_VERSION = '9'（硬编码），且 line342 findBinary 直接找 'napi-v9'。
#   napi backend 与 process.versions.modules 无关 —— 设备上是 Termux node 26 也不需要
#   nodeabi-v{modules}；只有 nodeabi backend 才用该 tag（本脚本不走该分支）。
# 期望产物完整路径（loader localBindingPath, index.js line464/558）:
#   <平台包目录>/build/napi/napi-v9-<platformPackageSuffix>/require_builtin.node
#   platformPackageSuffix = `${process.platform}-${process.arch}`
#     Termux android-arm64 → android-arm64；android-x86_64 → android-x64
#
# ── 编译宏（照抄上游 binding.gyp 的 napi 分支 defines）──
#   NAPI_VERSION=9  NODE_ADDON_API_DISABLE_CPP_EXCEPTIONS  NARB_BACKEND=1(napi)
#   NARB_PRODUCT=1(require-builtin) —— loader 的 productForPackage 校验
#   info.product === 'require-builtin'（node-addon-require-builtin 包），
#   .node 内 native_types.cc 用 "napi-v"<<NAPI_VERSION 生成 info.abi → "napi-v9" 匹配。
set -euo pipefail

ARCH="${1:-aarch64}"
case "$ARCH" in
  aarch64) ANDROID_ARCH=arm64 ;;
  x86_64)  ANDROID_ARCH=x64 ;;
  *) echo "ARCH 只支持 aarch64 或 x86_64，收到: $ARCH" >&2; exit 1 ;;
esac

# ── 路径常量：可用环境变量覆盖（CI/Linux 用），默认保持本机 Windows 布局 ──
OS_TAG="$(uname -s | grep -qi linux && echo linux-x86_64 || echo windows-x86_64)"
SRC_ROOT="${RB_SRC_ROOT:-$(cygpath -u 'D:/dsh-android/dsh-node-addon-require-builtin/packages/native' 2>/dev/null || echo "$PWD")}"
NDK="${RB_NDK:-${ANDROID_NDK_HOME:-D:/tools/android-sdk/ndk/29.0.14206865}}"
TOOLCHAIN="${NDK}/toolchains/llvm/prebuilt/${OS_TAG}"
DEPS="${RB_DEPS:-$(cygpath -u 'D:/dsh-android/deps' 2>/dev/null || echo /tmp/rb-deps)}"
OUT_DIR="${RB_OUT:-$(cygpath -u "D:/dsh-android/out/android-$ANDROID_ARCH" 2>/dev/null || echo "$PWD/out/android-$ANDROID_ARCH")}"
BUILD_ID="android-${ANDROID_ARCH}-napi-v9"

NODE_VER='22.15.0'   # napi 稳定 ABI，headers 版本只影响编译期可见的 napi_* 符号
NODE_HEADERS_URL="https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/v${NODE_VER}/node-v${NODE_VER}-headers.tar.gz"
NAAPI_VER='8.9.0'    # 上游 package.json: "node-addon-api": "^8.9.0"（pnpm-lock 锁 8.9.0）
NAAPI_URL="https://registry.npmmirror.com/node-addon-api/-/node-addon-api-${NAAPI_VER}.tgz"

CLANGXX="${TOOLCHAIN}/bin/clang++"
SYSROOT="${TOOLCHAIN}/sysroot"
TARGET="${ARCH}-linux-android24"   # Termux 最低 API 24

# ── 下载依赖（缓存到 DEPS，重复运行跳过）─────────────────────────────────
mkdir -p "$DEPS" "$OUT_DIR"

if [ ! -d "$DEPS/node-v$NODE_VER-headers/include/node" ]; then
  echo "[dep] 下载 node headers v$NODE_VER ..."
  curl -fL --retry 3 -o "$DEPS/node-headers.tar.gz" "$NODE_HEADERS_URL"
  mkdir -p "$DEPS/node-v$NODE_VER-headers"
  tar -xzf "$DEPS/node-headers.tar.gz" -C "$DEPS/node-v$NODE_VER-headers" --strip-components=1
fi

if [ ! -f "$DEPS/node-addon-api-$NAAPI_VER/napi.h" ]; then
  echo "[dep] 下载 node-addon-api $NAAPI_VER ..."
  curl -fL --retry 3 -o "$DEPS/node-addon-api.tgz" "$NAAPI_URL"
  mkdir -p "$DEPS/node-addon-api-$NAAPI_VER"
  tar -xzf "$DEPS/node-addon-api.tgz" -C "$DEPS/node-addon-api-$NAAPI_VER" --strip-components=1
fi

NODE_INC="$(cygpath -m "$DEPS/node-v$NODE_VER-headers/include")"
NAAPI_INC="$(cygpath -m "$DEPS/node-addon-api-$NAAPI_VER")"

# ── 源文件清单：binding.gyp 基础 sources + napi 分支追加（不含 nodeabi 文件）──
SOURCES=(
  src/node_api_addon.cc
  src/debug_trace.cc
  src/native_types.cc
  src/runtime_symbol.cc
  src/runtime_context/helper.cc
  src/runtime_context/platform.cc
  src/runtime_context/darwin_arm64.cc
  src/runtime_context/darwin_x64.cc
  src/runtime_context/linux_arm64.cc
  src/runtime_context/linux_x64.cc
  src/runtime_context/win32_arm64.cc
  src/runtime_context/win32_x64.cc
  src/runtime_context/win32_ia32.cc
  src/runtime_context/embedder_data.cc
  src/runtime_context/runtime_profile.cc
  src/runtime_context/runtime_profile_napi.cc
  src/runtime_probe/helper.cc
  src/runtime_probe/platform.cc
  src/runtime_probe/getter_decoder.cc
  src/runtime_probe/posix.cc
  src/runtime_probe/win32_common.cc
  src/runtime_probe/darwin_arm64.cc
  src/runtime_probe/darwin_x64.cc
  src/runtime_probe/linux_arm64.cc
  src/runtime_probe/linux_x64.cc
  src/runtime_probe/win32_arm64.cc
  src/runtime_probe/win32_x64.cc
  src/runtime_probe/win32_ia32.cc
  src/require_builtin_probe.cc
  src/runtime_compat_napi.cc
)

OBJ_DIR="$DEPS/obj-$BUILD_ID"
mkdir -p "$OBJ_DIR"
OBJ_WIN="$(cygpath -m "$OBJ_DIR")"

DEFINES=(
  -DNAPI_VERSION=9
  -DNODE_ADDON_API_DISABLE_CPP_EXCEPTIONS
  -DNARB_BACKEND=1
  -DNARB_PRODUCT=1
)
CXXFLAGS=(
  --target="$TARGET"
  --sysroot="$(cygpath -m "$SYSROOT")"
  -std=c++17 -O2 -fPIC
  -fno-exceptions -fvisibility=hidden
  -Wall -Wextra -Wno-unused-parameter
  -Wno-unknown-warning-option
  -I"$(cygpath -m "$SRC_ROOT/src")"
  -I"$NODE_INC/node"
  -I"$NAAPI_INC"
  "${DEFINES[@]}"
)

echo "[build] $TARGET → $OUT_DIR/require_builtin.node"
OBJS=()
for f in "${SOURCES[@]}"; do
  obj_name="$(echo "$f" | tr "/." "__").o"
  obj_posix="$OBJ_DIR/$obj_name"
  obj_win="$OBJ_WIN/$obj_name"
  # 简单增量：源比 obj 新才编译
  if [ ! -f "$obj_posix" ] || [ "$SRC_ROOT/$f" -nt "$obj_posix" ]; then
    echo "[cxx] $f"
    "$CLANGXX" "${CXXFLAGS[@]}" -c "$(cygpath -m "$SRC_ROOT/$f")" -o "$obj_win"
  fi
  OBJS+=("$obj_win")
done

OUT_WIN="$(cygpath -m "$OUT_DIR/require_builtin.node")"
"$CLANGXX" -shared -o "$OUT_WIN" "${OBJS[@]}" \
  --target="$TARGET" --sysroot="$(cygpath -m "$SYSROOT")" \
  -Wl,-soname,require_builtin.node

echo
echo "[ok] 产物: $OUT_DIR/require_builtin.node"
echo "[loader 期望路径] <平台包目录>/build/napi/napi-v9-android-$ANDROID_ARCH/require_builtin.node"
echo "  （平台包目录 = node-addon-require-builtin-android-$ANDROID_ARCH 的 npm 包安装目录，"
echo "    或 native-cache 对应目录；product/backend/abi 由 .node 自身 getNativeBindingInfo() 校验：require-builtin / napi / napi-v9）"
