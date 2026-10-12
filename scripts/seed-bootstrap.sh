#!/usr/bin/env bash
# dsh-android 构建时打种脚本（在 Ubuntu CI 上跑：需 curl / unzip / zip / dpkg-deb / nodejs+npm）
# 目标：产出定制 bootstrap zip，让 APK 离线首启即带 nodejs+npm、全局 dsh CLI、TUNA/npmmirror 镜像源。
# 产物直接覆盖 app/src/main/cpp/bootstrap-<arch>.zip；构建时用 -PdshSeededBootstrap 跳过远程下载。
set -euo pipefail

log(){ echo "[seed $(date +%H:%M:%S)] $*"; }

run_step(){
    local name="$1"; shift
    log ">>> $name"
    local t0=$SECONDS
    "$@"
    log "<<< $name 完成，用时 $(( SECONDS - t0 ))s"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADLE_FILE="$REPO_ROOT/app/build.gradle"
ARCH="${ARCH:-aarch64}"                       # aarch64 / arm / i686 / x86_64

# ---- 版本参数化：默认从 build.gradle 的 apt-android-7 分支读取，可用 BOOTSTRAP_VERSION 覆盖 ----
BASE_VER="$(sed -n 's/.*def version = "\([0-9][^"]*\)".*apt\.android-7.*/\1/p' "$GRADLE_FILE" | head -n1)"
if [[ -z "$BASE_VER" ]]; then
    log "错误：无法从 build.gradle 解析 bootstrap 版本，请手动设置 BOOTSTRAP_VERSION（如 2026.02.12-r1+apt.android-7）"
    exit 1
fi
BOOTSTRAP_VERSION="${BOOTSTRAP_VERSION:-${BASE_VER}+apt.android-7}"

APT_BASE="${APT_BASE:-https://packages.termux.dev/apt/termux-main}"
TUNA_APT="${TUNA_APT:-https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
DSH_PKG="${DSH_PKG:-@deepseek-ai/dsh@0.2.0-rc.2}"
ROOT_DEBS="${ROOT_DEBS:-nodejs}"              # 打种根包（逗号分隔；Termux 的 nodejs 自带 npm）
WORK="${WORK:-$REPO_ROOT/build/seed-$ARCH}"

log "ARCH=$ARCH  BOOTSTRAP_VERSION=$BOOTSTRAP_VERSION  APT_BASE=$APT_BASE"
log "WORK=$WORK"

# ---- 依赖闭包解析器（awk，被 fetch_packages 后的 resolve_closure 使用）----
# deb822 格式：Package/Depends/Pre-Depends/Filename，续行以空格/Tab 开头。
# Depends 处理约定：
#   - "a | b" 多候选取第一个（记录假设： Termux 里首选候选几乎都是真实唯一包）
#   - "name (>= 1.2)" 去掉版本约束、"[arch]" 去掉架构限定
CLOSURE_AWK='
function trim(s){gsub(/^ +| +$/,"",s);return s}
BEGIN{ tail=0 }
/^Package: /     { pkg=trim(substr($0,10)); last=""; next }
/^Depends: /     { dep[pkg]=substr($0,10); last="dep"; next }
/^Pre-Depends: / { dep[pkg]=dep[pkg] "," substr($0,14); last="dep"; next }
/^Filename: /    { fn[pkg]=trim(substr($0,11)); last="fn"; next }
/^[ \t]/         { if(last=="dep") dep[pkg]=dep[pkg] " " substr($0,2); else if(last=="fn") fn[pkg]=fn[pkg] trim(substr($0,2)); next }
/^[^ \t]/        { last="" }
END{
    n=split(root,start,",")
    for(i=1;i<=n;i++){ p=trim(start[i]); if(p!="" && seen[p]++==0) q[++tail]=p }
    head=1; cnt=0; miss=0
    while(head<=tail){
        p=q[head++]
        if(!(p in fn)){ missing[miss++]=p; continue }
        cnt++
        printf "PKG\t%s\t%s\n", p, fn[p]
        d=dep[p]
        if(d=="") continue
        m=split(d,parts,",")
        for(i=1;i<=m;i++){
            c=parts[i]
            sub(/\|.*/,"",c)            # 取第一个候选
            sub(/ ?\(.*$/,"",c)         # 去版本约束
            sub(/ ?\[.*$/,"",c)         # 去架构限定
            c=trim(c)
            if(c=="") continue
            if(seen[c]++==0) q[++tail]=c
        }
    }
    for(i=0;i<miss;i++) printf "MISSING\t%s\n", missing[i]
    printf "SUMMARY closed=%d missing=%d\n", cnt, miss > "/dev/stderr"
}'

# ---- a. 下载官方 bootstrap zip ----
fetch_bootstrap(){
    mkdir -p "$WORK"
    local enc="${BOOTSTRAP_VERSION//+/%2B}"
    local url="https://github.com/termux/termux-packages/releases/download/bootstrap-${enc}/bootstrap-${ARCH}.zip"
    log "下载：$url"
    curl -fL --retry 3 -o "$WORK/bootstrap-${ARCH}.zip.orig" "$url"
    ls -lh "$WORK/bootstrap-${ARCH}.zip.orig"
}

# ---- a2. 解包（zip 内即 dpkg-deb --extract 后的 usr 文件树：bin/ lib/ etc/ ...）----
unpack_bootstrap(){
    rm -rf "$WORK/stage"
    mkdir -p "$WORK/stage"
    ( cd "$WORK/stage" && unzip -q -o "../bootstrap-${ARCH}.zip.orig" )
    du -sh "$WORK/stage"
}

# ---- b. 拉 Packages 索引 ----
fetch_packages(){
    local p="$APT_BASE/dists/stable/main/binary-${ARCH}/Packages"
    if curl -fsSL --retry 3 -o "$WORK/Packages" "$p"; then
        log "已取得未压缩 Packages"
    else
        log "无未压缩 Packages，改拉 Packages.gz"
        curl -fL --retry 3 -o "$WORK/Packages.gz" "$p.gz"
        gunzip -f "$WORK/Packages.gz"
    fi
    ls -lh "$WORK/Packages"
}

# ---- b2. 递归依赖闭包 ----
resolve_closure(){
    awk -v root="${ROOT_DEBS// /,}" "$CLOSURE_AWK" "$WORK/Packages" > "$WORK/closure.tsv"
    log "闭包解析结果："
    column -t "$WORK/closure.tsv" || cat "$WORK/closure.tsv"
}

# ---- c. 逐个下载 .deb 并 --extract 合并进 stage（重复覆盖官方基础包无害）----
download_debs_extract(){
    mkdir -p "$WORK/debs"
    local total=$(grep -c '^PKG' "$WORK/closure.tsv") i=0 name path out
    while IFS=$'\t' read -r tag name path; do
        [[ "$tag" == "PKG" ]] || continue
        i=$((i+1))
        out="$WORK/debs/$(basename "$path")"
        [[ -s "$out" ]] || { log "[$i/$total] 下载 $path"; curl -fL --retry 3 -o "$out" "$APT_BASE/$path"; }
        log "[$i/$total] 解包 $name"
        dpkg-deb --extract "$out" "$WORK/stage"
    done < "$WORK/closure.tsv"
    du -sh "$WORK/stage"
}

# ---- d. 覆写 apt 源为 TUNA，官方源以注释形式备份 ----
inject_sources_list(){
    mkdir -p "$WORK/stage/etc/apt/sources.list.d"
    if [[ -f "$WORK/stage/etc/apt/sources.list" ]]; then
        sed 's|^|# original: |' "$WORK/stage/etc/apt/sources.list" \
            > "$WORK/stage/etc/apt/sources.list.d/00-official-backup.list"
    fi
    cat >> "$WORK/stage/etc/apt/sources.list.d/00-official-backup.list" <<EOF
# dsh-android 打种说明：默认官方源备份（当前生效源见 ../sources.list，已改为 TUNA 镜像）。
# 如需切回官方源：删除/注释 ../sources.list 里的 TUNA 行，取消下面注释即可。
# deb ${APT_BASE} stable main
EOF
    printf 'deb %s stable main\n' "$TUNA_APT" > "$WORK/stage/etc/apt/sources.list"
    log "sources.list -> $(cat "$WORK/stage/etc/apt/sources.list")"
}

# ---- e. dsh 注入：CI 有网，直接 npm 全局式安装到 stage（产物进 zip 后用户离线可用）----
inject_dsh(){
    command -v npm >/dev/null || { log "错误：CI 缺少 npm"; exit 1; }
    npm install --prefix "$WORK/stage" --no-audit --no-fund \
        --registry="$NPM_REGISTRY" "$DSH_PKG"
    # npm 会在 stage/lib/node_modules/@deepseek-ai/dsh 落全量依赖树；
    # stage/bin/dsh 是软链，Android 端解压器对软链支持不稳，改为固定启动壳。
    rm -f "$WORK/stage/bin/dsh"
    cat > "$WORK/stage/bin/dsh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash -e
exec /data/data/com.termux/files/usr/bin/node \
    /data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
EOF
    chmod 755 "$WORK/stage/bin/dsh"
    # npm 在 prefix 根顺手生成的清单文件不属于 usr 树布局，清掉
    rm -f "$WORK/stage/package.json" "$WORK/stage/package-lock.json"
    [[ -f "$WORK/stage/lib/node_modules/@deepseek-ai/dsh/lib/bin.js" ]] \
        || { log "错误：dsh 安装后未找到 lib/bin.js（检查包版本/registry）"; exit 1; }
    du -sh "$WORK/stage/lib/node_modules"
}

# ---- f. 重新打包回 build.gradle 期望的文件名，放回 cpp/ ----
repack(){
    local out="$WORK/bootstrap-${ARCH}.seeded.zip"
    rm -f "$out"
    # -y 保留符号链接条目；zip 存 unix 权限位，Android 端解压器按此恢复
    ( cd "$WORK/stage" && zip -q -X -r -y "$out" . )
    ls -lh "$out"
    cp -f "$out" "$REPO_ROOT/app/src/main/cpp/bootstrap-${ARCH}.zip"
    log "已覆盖：$REPO_ROOT/app/src/main/cpp/bootstrap-${ARCH}.zip"
    sha256sum "$REPO_ROOT/app/src/main/cpp/bootstrap-${ARCH}.zip"
}

main(){
    local t0=$SECONDS
    run_step "a. 下载官方 bootstrap (${BOOTSTRAP_VERSION})" fetch_bootstrap
    run_step "a2. 解包 bootstrap"            unpack_bootstrap
    run_step "b. 拉取 Packages 索引"          fetch_packages
    run_step "b2. 解析依赖闭包 (${ROOT_DEBS})" resolve_closure
    run_step "c. 下载 deb 并合并文件树"       download_debs_extract
    run_step "d. 注入 TUNA apt 源"            inject_sources_list
    run_step "e. 注入 dsh CLI"                inject_dsh
    run_step "f. 重新打包并放回 cpp/"          repack
    log "全部完成，总用时 $(( SECONDS - t0 ))s"
    log "构建：./gradlew assembleRelease -PdshSeededBootstrap（跳过下载与校验，直接用打种 zip）"
}

main "$@"
