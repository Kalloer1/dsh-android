#!/usr/bin/env bash
# 本机最小自检（Windows Git Bash / WSL 可跑，只依赖 curl + awk）：
# 仅执行 seed-bootstrap.sh 的 b 步——Packages 索引下载 + nodejs 依赖闭包解析，打印包名+Filename。
# 完整打种流程（dpkg-deb / npm / zip）只应在 Ubuntu CI 上跑。
set -euo pipefail

APT_BASE="${APT_BASE:-https://packages.termux.dev/apt/termux-main}"
ARCH="${ARCH:-aarch64}"
ROOT_DEBS="${ROOT_DEBS:-nodejs}"
TMP_DIR="${TMP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/build/seed-local-test}"
mkdir -p "$TMP_DIR"
PACKAGES="$TMP_DIR/Packages"

if [[ ! -s "$PACKAGES" ]]; then
    echo "[test] 下载 Packages 索引：$APT_BASE/dists/stable/main/binary-${ARCH}/Packages" >&2
    if curl -fsSL --retry 3 -o "$PACKAGES" "$APT_BASE/dists/stable/main/binary-${ARCH}/Packages"; then
        echo "[test] 使用未压缩 Packages" >&2
    else
        echo "[test] 未压缩 Packages 不可用，回退 Packages.gz" >&2
        curl -fL --retry 3 -o "$PACKAGES.gz" "$APT_BASE/dists/stable/main/binary-${ARCH}/Packages.gz"
        gunzip -f "$PACKAGES.gz"
    fi
else
    echo "[test] 复用已有缓存 $PACKAGES" >&2
fi
ls -lh "$PACKAGES" >&2

# 与 seed-bootstrap.sh 中 CLOSURE_AWK 保持一致的解析器
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
            sub(/\|.*/,"",c)            # 多候选取第一个（假设记录：首选候选即真实包名）
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

echo "[test] 解析根包：$ROOT_DEBS 的完整依赖闭包" >&2
OUT="$TMP_DIR/closure.tsv"
awk -v root="${ROOT_DEBS// /,}" "$CLOSURE_AWK" "$PACKAGES" > "$OUT"

echo "---- 包名 -> Filename ----"
grep '^PKG' "$OUT" | cut -f2,3 | sed 's/\t/  ->  /'
MISSING_LIST=$(grep '^MISSING' "$OUT" | cut -f2 | tr '\n' ' ' || true)
CNT=$(grep -c '^PKG' "$OUT")
echo "--------------------"
echo "[test] 闭包包数：$CNT"
if [[ -n "$MISSING_LIST" ]]; then
    echo "[test] 警告：索引中缺失的依赖（不阻塞，CI 会跳过）：$MISSING_LIST"
else
    echo "[test] 无缺失依赖"
fi

if [[ "$CNT" -eq 0 ]]; then
    echo "[test] FAIL：闭包为空，解析逻辑或索引地址有问题" >&2
    exit 1
fi
echo "[test] PASS"
