# dsh-android

> 本文件是 fork 的说明页，不替代上游 [README.md](README.md)。

## 这是什么

dsh web 的**手机本地版 APK**：基于 [Termux](https://termux.com) 应用改造，
让 dsh（对话/agent 工具）直接跑在 Android 上——GitHub 授权、流式对话、
内置终端抽屉，全程本地进程，不依赖服务器中转。

- Fork 自上游：<https://github.com/termux/termux-app>（remote `origin`）
- 本仓库：`git@github.com:Kalloer1/dsh-android.git`（remote `dsh`），开发分支 `dsh-android`
- 基线版本：Termux app 0.118.0（`versionCode 118`），minSdk 21 / targetSdk 28 / compileSdk 36

## 许可证与上游出处

上游 termux-app 采用 **GPLv3**，本 fork 同样以 GPLv3 发布（见
[LICENSE.md](LICENSE.md)，全文与来源声明见上游 README）。使用、修改、再分发
须遵循 GPLv3：衍生作品须以同许可证开源，并保留本出处声明。Bootstrap 文件系统
包来自 <https://github.com/termux/termux-packages>（构建时由 gradle 任务
`downloadBootstraps` 按校验和下载，或由 `scripts/seed-bootstrap.sh` 预置）。

## 当前状态

- 应用代码：Termux 基线 + dsh 改造进行中（app/ 模块，具体进度见各模块任务卡）
- CI：`.github/workflows/dsh-android-build.yml`（本仓库新增）
  - push `dsh-android` 分支 → artifact
  - push `v*` tag → GitHub Release（附 universal APK + sha256sums）
- 签名：正式 keystore **尚未配置**，当前 CI 降级用上游测试 key
  （`testkey_untrusted.jks`）签名，仅可侧载自测。配置方法见
  [.github/keystore-README.md](.github/keystore-README.md)。

## 构建方式

**CI（推荐）**：Actions 页 → *DSH Android Release Build* →
<https://github.com/Kalloer1/dsh-android/actions/workflows/dsh-android-build.yml>
（占位链接，仓库改名后请以实际地址为准）。

**本地**：需要 JDK 17 + Android SDK（platform 36、build-tools 36、NDK
29.0.14206865，AGP 8.13.2 / Gradle 9.2.1 由 wrapper 自动拉取）：

```bash
./gradlew assembleRelease   # 产物在 app/build/outputs/apk/release/，默认未签名
./gradlew assembleDebug     # debug 包自带测试签名
```

## 验收线（一个 APK 走完全程）

1. **侧载安装**：release APK 可直接安装到 Android 手机（minSdk 21）。
2. **点开**：应用冷启动不闪退，进入主界面。
3. **GitHub 授权**：完成 GitHub 登录/授权流程，token 落在本地。
4. **流式对话**：发起对话，回复逐 token 流式渲染。
5. **终端抽屉**：从抽屉拉出内置终端，可输入命令执行。
6. **杀进程会话仍在**：从最近任务划掉应用（或 `am kill`）后重开，
   对话会话与运行中的终端 session 恢复，不丢历史、不断流。
