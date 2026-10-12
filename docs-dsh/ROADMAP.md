# dsh-android 路线图（2026-10-12 构建日志实录）

## 已完成
- fork `Kalloer1/dsh-android`（termux-app 0.118.0，分支 dsh-android，GPLv3）
- CI：打种→下载→编译→正式签名→artifacts 全链首绿（run 38295755581，APK 363MB）
- keystore：PKCS12 别名 dsh-android（2056 到期），secrets 已配，备份 `D:\dsh-android\secrets\`
- bootstrap 打种：nodejs(26.4.0)+dsh 0.2.0-rc.2 全局壳+TUNA apt+npmmirror 运行时 .npmrc
- home 打种：profiles/web 预铺 @deepseek-ai/dsh-base+dsh-web-app+dsh-our-free-model@2.1.0+dsh-web-mobile@3.0.6（零 symlink，distribution=managed，跳过欢迎弹窗），启动时 cp -rn 展开
- App 层：DshWebActivity（token URL 轮询加载、OAuth 跳外部浏览器、重试页、终端入口、电池豁免一次性引导）+ DshWebService（前台服务、指数退避、看门狗端口探测）
- Android 死雷补丁：flock loader 放行 android（bin-android/system.node → no-op 兜底）+ link(2) EPERM/EACCES→copy 降级；NDK 交叉编译 bionic system.node
- dsh 实测契约：`dsh web --no-open --host 127.0.0.1 --port 3080`，stdout 每轮新 token，cookie 接管会话

## 进行中
- 构建 #7：首次带 e3/e4 补丁步全链验证

## 待办（按优先级）
1. 真机验收：雷电模拟器 Android 14 x86_64（root 已开）跑 #10 双 ABI APK；mi8 待用户决定是否卸载官方 Termux
2. ~~ABI 拆分瘦身~~ 已改双 ABI 打种（aarch64+x86_64）；32 位 arm/i686 维持官方 bootstrap（无 dsh，超旧设备不在射程）
3. 免费渠道真机点亮：`/v1/models` 出现 EAC 模型 + GitHub 授权闸门全流程（vault 判定 web profile 应放行，未实锤）
4. rc.2 顶栏重叠已知 issue #202 → 补丁层插件 dsh-android-patch（client 注入形状已从 dsh-web-mobile@3.0.6 解出，未建工程）
5. MIUI 自启动白名单实测（mi8 即 MIUI，验收不过再特判）
6. 包名决策：维持 com.termux（文档要求先卸载其它 Termux）vs 改 com.dsh.android 共存
7. v0.1.0 tag 发首个 GitHub Release
