#!/data/data/com.termux/files/usr/bin/bash
# dsh-android 真机体检：经 ssh 在 Termux 里跑，定位 Android 特有三雷（link2/flock/启动契约）。
# 用法：ssh <phone> "bash -lc '/path/to/device-check.sh'"
set -uo pipefail
say(){ echo "[$1] $2"; }

# 0. 环境
node -v >/dev/null 2>&1 && say OK "node $(node -v)" || say FAIL "node 不存在（APK 打种未生效或先用 pkg install nodejs）"
command -v dsh >/dev/null && say OK "dsh shim: $(dsh --version 2>&1 | head -1)" || say FAIL "dsh 不在 PATH"

# 1. link(2) 硬链接探测（SELinux 拦 app 私有目录硬链接 → dsh 会话原子发布会坏）
cd "$HOME"; rm -f _lk_a _lk_b
echo t > _lk_a
if ln _lk_a _lk_b 2>/dev/null; then say OK "link(2) 可用，dsh 会话原子发布无障碍"; rm -f _lk_a _lk_b; else say RISK "link(2) 被拒: $(ln _lk_a _lk_b 2>&1 | head -1) —— dsh sessions 写入需实测确认回退"; rm -f _lk_a; fi

# 2. flock native addon 探测（无 bionic prebuilt → 看加载失败还是回退）
D="$HOME/.dsh"
mkdir -p "$D"
cat > "$D/_flock_probe.js" <<'EOF'
const fs=require('fs');
(async()=>{
  let dir=null;
  const bases=["/data/data/com.termux/files/usr/lib/node_modules/@deepseek-ai",""+process.env.DSH_ADDON_BASE||""];
  for(const b of bases){ try{ for(const p of fs.readdirSync(b)){ if(p.includes("node-addon-system")) dir=b+"/"+p; } }catch(e){} }
  if(!dir){ console.log("NOADDON"); return; }
  const cand=fs.readdirSync(dir+"/prebuilds").concat(fs.readdirSync(dir).filter(f=>f.endsWith(".node")));
  console.log("PREBUILDS:",cand.join(","));
  const main=require(dir);
  try{ const s=fs.openSync("/tmp/fp","w"); console.log("FLOCK_FN:", typeof (main.flock||main.lock||main.default?.flock)); }catch(e){ console.log("LOAD_ERR:",e.message.slice(0,120)); }
})();
EOF
node "$D/_flock_probe.js" 2>&1 | sed 's/^/[addon] /'

# 3. 启动契约实测（token 行为与 PC 一致？）
rm -f "$HOME/.dsh-web.log"
( env DSH_PERMISSION_MODE=danger-full-access DSH_TELEMETRY_DISABLED=1 DSH_CONFIRM=1 BROWSER=true \
    dsh web --no-open --host 127.0.0.1 --port 3080 > "$HOME/.dsh-web.log" 2>&1 & echo $! > /tmp/dsh.pid )
for i in $(seq 1 30); do
  URL=$(grep -o "http://127.0.0.1:3080/?token=[A-Za-z0-9_-]*" "$HOME/.dsh-web.log" | head -1) && [ -n "$URL" ] && break
  sleep 1
done
[ -z "$URL" ] && { say FAIL "30s 没等到 token 行"; tail -5 "$HOME/.dsh-web.log"; } || {
  say OK "token URL 就绪"
  CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 8 "http://127.0.0.1:3080/")
  [ "$CODE" = "401" ] && say OK "无 token=401（fence 生效）" || say RISK "无 token=$CODE（与预期 401 不符）"
  curl -s -c /tmp/ck -o /dev/null -m 15 "$URL"
  C=$(curl -s -b /tmp/ck -o /tmp/page.html -w "%{http_code}" -m 15 "http://127.0.0.1:3080/")
  SIZE=$(wc -c </tmp/page.html)
  [ "$C" = "200" ] && [ "$SIZE" -gt 2000 ] && say OK "cookie 会话 200，首页 ${SIZE}B" || say FAIL "cookie 会话 $C/${SIZE}B"
  # 4. 真发一条消息（有 key 才测；无 key 只验证 API 路由活着）
  M=$(curl -s -b /tmp/ck -m 10 http://127.0.0.1:3080/api/health 2>/dev/null | head -c 120)
  say INFO "api/health: $M"
}
kill "$(cat /tmp/dsh.pid)" 2>/dev/null
say DONE "体检结束"
