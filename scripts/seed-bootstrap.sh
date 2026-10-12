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
DSH_VER="${DSH_PKG##*@}"
PLUGIN_FREE_MODEL="${PLUGIN_FREE_MODEL:-dsh-our-free-model@2.1.0}"
PLUGIN_MOBILE_UI="${PLUGIN_MOBILE_UI:-dsh-web-mobile@3.0.6}"
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
# 注意：Termux deb 的 data.tar 路径是 data/data/com.termux/files/usr/...，
# 而 bootstrap zip（=stage）布局是 prefix 相对（bin/ lib/ etc/），必须剥壳再合并，
# 否则文件全落进 stage/data/... 的死层级里（node 找不到）。
download_debs_extract(){
    mkdir -p "$WORK/debs"
    local total=$(grep -c '^PKG' "$WORK/closure.tsv") i=0 name path out tmp
    while IFS=$'\t' read -r tag name path; do
        [[ "$tag" == "PKG" ]] || continue
        i=$((i+1))
        out="$WORK/debs/$(basename "$path")"
        [[ -s "$out" ]] || { log "[$i/$total] 下载 $path"; curl -fL --retry 3 -o "$out" "$APT_BASE/$path"; }
        log "[$i/$total] 解包 $name"
        tmp="$WORK/debroot/$i"
        rm -rf "$tmp"; mkdir -p "$tmp"
        dpkg-deb --extract "$out" "$tmp"
        # Termux deb 的 data.tar 路径实测为 usr/bin/node（前缀多一层 usr/，home/ 在
        # prefix 外忽略）；个别打包形态可能直接是 data/data/com.termux/files/usr/...
        # 或已经 prefix 相对。三种布局逐一识别后统一剥到 stage 根。
        if [[ -d "$tmp/data/data/com.termux/files/usr" ]]; then
            cp -a "$tmp/data/data/com.termux/files/usr/." "$WORK/stage/"
        elif [[ -d "$tmp/usr" ]]; then
            cp -a "$tmp/usr/." "$WORK/stage/"
        else
            cp -a "$tmp/." "$WORK/stage/"
        fi
        rm -rf "$tmp"
    done < "$WORK/closure.tsv"
    du -sh "$WORK/stage"
    [[ -x "$WORK/stage/bin/node" || -f "$WORK/stage/bin/node" ]] \
        || { log "错误：合并后 stage/bin/node 不存在，剥壳逻辑失效"; exit 1; }
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
# 构建源与运行时分家：npmmirror 对 @deepseek-ai/dsh 的新传递依赖（@aws-sdk/*）同步滞后
# 会 E404，构建默认官方 registry（CI 在美西，快），失败兜底 npmmirror；
# npmmirror 只烤进用户运行时 $PREFIX/etc/npmrc。
inject_dsh(){
    command -v npm >/dev/null || { log "错误：CI 缺少 npm"; exit 1; }
    local ok=0 reg
    for reg in "${BUILD_NPM_REGISTRY:-https://registry.npmjs.org}" "$NPM_REGISTRY"; do
        log "尝试从 $reg 安装 $DSH_PKG"
        # -g + --prefix：产物落 stage/lib/node_modules（$PREFIX 布局），
        # 不带 -g 的 --prefix 是局部语义会落 stage/node_modules（错误布局）
        if npm install -g --prefix "$WORK/stage" --no-audit --no-fund --omit=optional --registry="$reg" "$DSH_PKG"; then
            ok=1; break
        fi
        log "源 $reg 失败，清理后换源重试"
        rm -rf "$WORK/stage/lib/node_modules" "$WORK/stage/node_modules" "$WORK/stage/package.json" "$WORK/stage/package-lock.json"
    done
    [[ $ok -eq 1 ]] || { log "错误：所有 registry 均安装失败"; exit 1; }
    # 用户运行时镜像（设备端 npm 补装用）
    mkdir -p "$WORK/stage/etc"
    printf 'registry=%s\n' "$NPM_REGISTRY" > "$WORK/stage/etc/npmrc"
    # npm 会在 stage/lib/node_modules/@deepseek-ai/dsh 落全量依赖树；
    # stage/bin/dsh 是软链，Android 端解压器（Java ZipInputStream）不处理 symlink 条目，
    # 改为实体启动壳。
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

# ---- e2. dsh home 打种：预初始化 web profile + 内置两插件（免 pnpm、免 symlink）----
# 配方出处：docs/INTEGRATION-dsh.md §3.2（插件 README 官方离线铺法）：
#   文件铺进 profiles/web/node_modules/<插件>/ + package.json dependencies 登记
#   + dsh.profile.bundles 末尾追加。禁止 cordis.patch.yml 重复注册、禁止任何 symlink。
# 产物放进 prefix 的 share/dsh-seed/home/.dsh（zip 只含 prefix 相对路径，$HOME 在 prefix 外，
# 由 DshWebService 启动时 cp -rn 展开）。
inject_dsh_profiles(){
    command -v npm >/dev/null || { log "错误：CI 缺少 npm"; exit 1; }
    local seed="$WORK/dshseed/home/.dsh"
    rm -rf "$WORK/dshseed"
    mkdir -p "$seed/profiles/web"

    log "以 --no-bin-links 预装 web profile（扁平 node_modules、零 symlink）"
    ( cd "$seed/profiles/web" && npm install --no-bin-links --no-audit --no-fund --omit=optional \
        --registry="${BUILD_NPM_REGISTRY:-https://registry.npmjs.org}" \
        "@deepseek-ai/dsh-base@${DSH_VER}" "@deepseek-ai/dsh-web-app@${DSH_VER}" \
        "$PLUGIN_FREE_MODEL" "$PLUGIN_MOBILE_UI" )
    # profile 根文件（对齐 dsh 自动生成版的注释壳）
    cat > "$seed/profiles/web/cordis.yml" <<'EOF'
# dsh profile root — the tree is composed as patches: each bundle in
# package.json's dsh.profile.bundles, then cordis.patch.yml, then overlays.
[]
EOF
    printf '[]\n' > "$seed/profiles/web/cordis.patch.yml"
    node -e '
const fs=require("fs");const p=process.argv[1];
const d=JSON.parse(fs.existsSync(p)?fs.readFileSync(p,"utf8"):"{}");
d.name="dsh-profile-web"; d.private=true; d.version=d.version||"1.0.0";
d.dependencies=d.dependencies||{};
const prof=(d.dsh&&d.dsh.profile)||{};
d.dsh={...(d.dsh||{}),profile:{...prof,bundles:[
  "@deepseek-ai/dsh-base","@deepseek-ai/dsh-web-app","dsh-our-free-model","dsh-web-mobile"]}};
fs.writeFileSync(p,JSON.stringify(d,null,2));
' "$seed/profiles/web/package.json"
    # 内置插件必设 managed，禁插件自升级与 APK 受管更新打架（§3.3）
    mkdir -p "$seed/our-free-model"
    printf '{\n  "distribution": "managed"\n}\n' > "$seed/our-free-model/settings.json"
    # 首启设置：预记欢迎公告版本，跳过弹窗
    printf 'ui-onboarding:\n  welcomeNoticeVersion: "2026-08-13.1"\n' > "$seed/settings.yaml"
    # 硬闸：全树不允许出现 symlink（profile 闸门遇到外来链接拒启）
    local links; links=$(find "$seed" -type l | wc -l)
    [[ "$links" -eq 0 ]] || { log "错误：种子树含 $links 个 symlink，违反 profile 闸门"; find "$seed" -type l | head; exit 1; }
    mkdir -p "$WORK/stage/share"
    rm -rf "$WORK/stage/share/dsh-seed"
    cp -a "$WORK/dshseed/home" "$WORK/stage/share/dsh-seed"
    du -sh "$WORK/stage/share/dsh-seed"
}

# ---- e3. Android 持久层补丁（flock loader + link(2) 降级，幂等 python 脚本）----
patch_android(){
    command -v python3 >/dev/null || { log "错误：CI 缺少 python3"; exit 1; }
    python3 "$REPO_ROOT/scripts/patch-android-persistence.py" "$WORK"
    # 幂等重跑一遍证明可重复
    python3 "$REPO_ROOT/scripts/patch-android-persistence.py" "$WORK" | grep -q "skip" || true
}

# ---- e4. 交叉编译 bionic flock addon（NDK 在场才跑；产物随 e3 的 loader 补丁生效）----
build_flock_addon(){
    local node_ver
    node_ver=$(sed -n 's|.*nodejs/nodejs_\([0-9.]*\)-[0-9]*_aarch64.deb.*|\1|p' "$WORK/closure.tsv" | head -1)
    STAGE="$WORK/stage" WORK="$WORK/flockbuild" NODE_VER="${node_ver:-${NODE_VER:-26.4.0}}" \
        bash "$REPO_ROOT/scripts/build-flock-addon-android.sh"
}

# ---- f. 重新打包回 build.gradle 期望的文件名，放回 cpp/ ----
repack(){
    local out="$WORK/bootstrap-${ARCH}.seeded.zip"
    rm -f "$out"
    # TermInstaller 用 Java ZipInputStream 解流：不认 symlink 条目（会把链接目标字符串
    # 当文件内容写出去，成品是坏文件），官方 zip 因此把软链全记在 SYMLINKS.txt。
    # 打种新增的软链（deb/npm 带来）一律解引用存实体副本；官方 SYMLINKS.txt 原样保留
    # （TermInstaller 靠它重建基础软链，且缺它必抛异常）。
    # 实体软链数量应远小于解引用体积代价，若 bin/ 冲突由后写覆盖。
    ( cd "$WORK/stage" && zip -q -X -r "$out" . )
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
    run_step "e2. dsh home 打种(profile+插件)" inject_dsh_profiles
    run_step "e3. Android 持久层补丁"          patch_android
    if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
        run_step "e4. 编译 bionic flock addon" build_flock_addon
    else
        log "e4 跳过：无 ANDROID_NDK_HOME（本机模式，loader 将走 no-op 锁兜底）"
    fi
    run_step "f. 重新打包并放回 cpp/"          repack
    log "全部完成，总用时 $(( SECONDS - t0 ))s"
    log "构建：./gradlew assembleRelease -PdshSeededBootstrap（跳过下载与校验，直接用打种 zip）"
}

main "$@"
