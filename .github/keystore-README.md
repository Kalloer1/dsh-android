# dsh-android release 签名 keystore 一次性配置指南

> **状态（2026-10-12）：已配置完成。** 四个 repository secrets 均已写入
> `Kalloer1/dsh-android`；keystore 为 openssl 生成的 PKCS12（别名 `dsh-android`，
> 自签 RSA2048，有效期至 2056-10-04），本地备份在仓库主机器
> `D:\dsh-android\secrets\dsh-release.p12 + dsh-release.password`。
> **务必备离机副本**——p12 或密码丢失后，已发布版本将无法被同 key 升级覆盖。
> 以下为原始指南（换 key 时用）。

CI（`.github/workflows/dsh-android-build.yml`）构建 release APK 时会检查下面四个
repository secrets；齐全就用正式 key 签名，缺失则降级用仓库自带的
`app/testkey_untrusted.jks`（与 debug 构建同款、上游标记 untrusted 的测试 key）
签名并在构建 summary 中警告。**正式对外发布前请完成本指南。**

## 1. 生成 keystore（本机执行一次，妥善备份）

Linux / macOS / Windows Git Bash：

```bash
keytool -genkeypair -v \
  -keystore dsh-release.jks \
  -alias dsh-release \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -storepass '换成你自己的强密码' \
  -keypass '换成你自己的强密码' \
  -dname "CN=dsh-android, OU=dsh, O=dsh, L=Internet, ST=None, C=CN"
```

要点：
- alias 叫什么都行，记住它，第 3 步要填进 secret。
- `dsh-release.jks` 一旦用于发布就**永久不能丢**：丢了将无法给已安装用户推送
  同签名更新（只能换包名重新发布）。请至少异地备份两份（如密码管理器附件 + 加密网盘）。
- Windows cmd 也可用 `keytool`（需装 JDK），或在 Git Bash 里执行。

## 2. 把 keystore 转成 base64

Linux/macOS：

```bash
base64 -w0 dsh-release.jks > dsh-release.jks.b64
```

Windows Git Bash：

```bash
base64 dsh-release.jks | tr -d '\n' > dsh-release.jks.b64
```

（cmd 下可用 `certutil -encode dsh-release.jks dsh-release.jks.b64`，再手动删掉
`-----BEGIN/END CERTIFICATE-----` 两行头尾并把多行拼成一行。）

打开 `dsh-release.jks.b64`，复制那一整行内容备用。**不要**把 `.jks` 或 `.b64`
提交进仓库。

## 3. 在 GitHub 仓库配置 4 个 secrets

仓库页面 → **Settings** → **Secrets and variables** → **Actions** →
**New repository secret**，逐个添加（Name 必须一字不差）：

| Secret 名 | 值 |
| --- | --- |
| `DSH_KEYSTORE_BASE64` | 第 2 步 base64 的**整行内容** |
| `DSH_KEYSTORE_PASSWORD` | 第 1 步的 `-storepass` |
| `DSH_KEY_ALIAS` | 第 1 步的 `-alias`（示例：`dsh-release`） |
| `DSH_KEY_PASSWORD` | 第 1 步的 `-keypass` |

secrets 只影响 GitHub Actions，不会暴露给 PR 来源分支（fork PR 读不到，属正常）。

## 4. 验证

打一个测试 tag 触发 CI：

```bash
git tag v0.118.0-test1
git push dsh v0.118.0-test1
```

构建成功后，在 Actions 页面看 job summary：签名方式应显示
`release`（而不是 `untrusted-testkey`）。下载 APK 本地复核：

```bash
$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs dsh-release.apk
# 或
apksigner verify --print-certs dsh-release.apk
```

证书 Subject 应是你第 1 步填的 `CN=dsh-android...`。

## 5. 之后换 key / 泄露应急

- 换 keystore = 老用户无法覆盖安装，需换包名或让用户先卸载。除非 key 泄露，
  否则不要换。
- key 泄露：立即在 repo settings 删除/替换 secrets，新发布用新 key，公告用户
  旧包不再可信。
