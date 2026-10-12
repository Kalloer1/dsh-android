# 包名固定 com.termux：不与已装 Termux 的设备共存

dsh-android 沿用 applicationId `com.termux`。上游 TermuxConstants 注释明示：改包名必须重编 bootstrap 全部二进制（路径焊死 /data/data/com.termux/files/usr），而本项目的价值恰在复用官方 bionic 打种链，重编 termux-packages 不在预算内。

## Consequences

- 与任何已安装的 com.termux（签名不同）互斥：安装前必须先卸载既有 Termux，用户数据由 Termux 自带备份工具迁移（同包同前缀，魔改版可还原官方备份）。
- 分发文案与 Release 说明必须写明此前置动作。
- App 名称/图标/桌面入口均自定义（"dsh"），仅包 id 共用，用户视觉上无 Termux 痕迹。
