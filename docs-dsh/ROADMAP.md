# dsh-android 路线图（2026-10-12 构建日志实录）

## 已完成
- fork `Kalloer1/dsh-android`（termux-app 0.118.0，分支 dsh-android，GPLv3）
- CI：打种→下载→编译→正式签名→artifacts 全链首绿（run 38295755581，APK 363MB）
- keystore：PKCS12 别名 dsh-android（2056 到期），secrets 已配，备份 `D:\dsh-android\secrets\`
- bootstrap 打种：nodejs(26.4.0)+dsh 0.2.0-rc.2 全局壳+TUNA apt+npmmirror 运行时 .npmrc
- home 打种：profiles/web 预铺 @deepseek-ai/dsh-base+dsh-web-app+dsh-our-free-model@1.4.4+dsh-web-mobile@3.0.6+dsh-android-patch（零 symlink，distribution=managed，跳过欢迎弹窗），启动时 cp -rn 展开
- App 层：DshWebActivity（token URL 轮询加载、OAuth 跳外部浏览器、重试页、终端入口、电池豁免一次性引导）+ DshWebService（前台服务、指数退避、看门狗端口探测）
- Android 死雷补丁：flock loader 放行 android（bin-android/system.node → no-op 兜底）+ link(2) EPERM/EACCES→copy 降级；NDK 交叉编译 bionic system.node
- dsh 实测契约：`dsh web --no-open --host 127.0.0.1 --port 3080`，stdout 每轮新 token，cookie 接管会话

## 进行中
- 构建 #7：首次带 e3/e4 补丁步全链验证

## 2026-10-13 模拟器验收实录（雷电 Android 14 x86_64）
- 触摸注入坐标校准后全 UI 可驱动；dsh-web-mobile@3.0.6 移动端布局生效（底部导航+浮动+）
- 新会话创建 ✓；免费模型 MiMo V2.6 流式回答 ✓（「你好！有什么我可以帮你的吗？」）
- 免费渠道换钉 dsh-our-free-model@1.4.4：OpenCode Zen 零登录零 Key（2.1.0 的 EAC+GitHub 闸门与"点开即用"冲突，放弃）
- 修复并入库：WebView window.open→系统浏览器（onCreateWindow）；patch 插件 cordis 入口形状（name+apply）与 client 工厂 module/exports；打种器 isLinkDenied 双注入；require_builtin 双树注入；流式 bootstrap 解包（JNI OOM 根因）
- 正式 APK 全链本地构建：seed(363s)→gradle→apksigner→adb install 已通

## 2026-10-13 品牌化 + persona 双注册修复
- 应用名改 `DeepSeek Harness`（launcher label + application label）
- 图标换成用户指定的蓝毛女仆小人（纯 Python 生成自适应图标：各 dpi foreground + 深蓝底 background + legacy 圆/方图）
- 换一套全新自签密钥（dsh-release2.p12，别名 dsh-android，~2056 到期），CI secrets 同步更新；包名维持 com.termux（改包名需重编整套 termux 二进制，共存靠卸载官方 Termux）
- 免费插件回到 dsh-our-free-model@2.1.0（OpenCode 1.4.4 上游已封），撤 vendor tarball；不写入任何外部 API key
- 关键修复：seed 装插件时 npm 把 peerDependencies（dsh-llm/dsh-commands/cordis…）连同整棵核心树复制进 profiles/web/node_modules，致 dsh-system-prompt 双加载、新建会话报 `agent-preset/invalid: persona … deployment:persona-prefix already registered`。加 `--legacy-peer-deps` + "profiles 内不得有 @deepseek-ai 核心包"硬闸修复；全新 APK 实测建会话成功

## 待办（按优先级）
1. 全新安装终验：卸载清数据→装 1.4.4 打种 APK→首启解包→弹窗→建会话→免费模型回答（验收脚本化）
2. ~~ABI 拆分瘦身~~ 已改双 ABI 打种（aarch64+x86_64）；32 位 arm/i686 维持官方 bootstrap（无 dsh，超旧设备不在射程）
3. ~~免费渠道真机点亮~~ 1.4.4 零登录通道模拟器实锤；mi8 真机复验待用户卸载官方 Termux
4. rc.2 顶栏重叠已知 issue #202 → 补丁层插件 dsh-android-patch（已建工程并导入成功，CSS 修正待真机取证）
5. MIUI 自启动白名单实测（mi8 即 MIUI，验收不过再特判）
6. 包名决策：维持 com.termux（文档要求先卸载其它 Termux）vs 改 com.dsh.android 共存
7. v0.1.0 tag 发首个 GitHub Release
