# Codex iPad

一个自用的原生 iPad SSH 连接原型。当前版本只负责连接远端 Linux 服务器，尚未接入 Codex 会话。

## 已实现

- SwiftUI 界面，支持 iPad 横竖屏、浅色和深色外观。
- 填写主机地址、端口、用户名和密码，执行真正的 SSH 密码认证。
- 首次连接显示 SHA256 主机指纹，由用户核对后保存到设备钥匙串；指纹变化时阻止连接。
- 登录后读取主机名、用户名、内核版本、Home 目录。
- 断开连接，以及检测已关闭的 SSH 通道。
- 保存地址和用户名；密码只保留在进程内存中，成功连接后清空输入框。

## 在 Mac 上运行

要求：Xcode 16 或更新版本；iPadOS 17 或更新版本。Windows 不能编译或签名 iPad App。

1. 在 Mac 上获取本仓库，打开 `CodexIPad.xcodeproj`。
2. 等待 Xcode 下载 Swift Package 依赖。Citadel 固定为 **0.12.1**，无需 CocoaPods 或 XcodeGen。
3. 选择 **CodexIPad** target → **Signing & Capabilities**，选择自己的开发者 Team；如有冲突，修改 Bundle Identifier。
4. 选择 iPad 模拟器或已配对的真实 iPad，运行。
5. 输入服务器地址、SSH 端口、用户名和该服务器的密码。
6. 首次连接先核对指纹，再点击“信任并连接”。看到系统信息即连接成功。

默认地址 `10.10.0.172` 是局域网地址。外出时请先连接 ZeroTier，并改用服务器实际的 ZeroTier IP 或可达域名。第一次访问局域网时请允许系统弹出的本地网络权限。

在服务器上核对 SSH 主机指纹（只读取公钥）：

```sh
for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key" -E sha256; done
```

将 App 显示的 SHA256 指纹与对应的服务器公钥进行比较。第一版只支持密码认证；如果服务器只接受私钥，请先不要修改服务器安全设置，后续增加 App 的私钥认证功能即可。认证不支持键盘交互或双因素登录。

## 验证

项目包含输入校验及 OpenSSH 指纹格式的 XCTest。在 Xcode 中按 **⌘U** 运行；测试不需要服务器密码。

命令行检查（Mac）：

```sh
xcodebuild -resolvePackageDependencies -project CodexIPad.xcodeproj -scheme CodexIPad
xcodebuild -project CodexIPad.xcodeproj -scheme CodexIPad \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -showdestinations -project CodexIPad.xcodeproj -scheme CodexIPad
# 将下面的 ID 替换为上一条命令列出的可用 iPad 模拟器 ID
xcodebuild -project CodexIPad.xcodeproj -scheme CodexIPad \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' CODE_SIGNING_ALLOWED=NO test
```

当前工程在 Windows 上生成，已经通过 OpenStep 工程文件解析、工程引用完整性、源文件路径、Info.plist、共享 Scheme 和工程生成一致性检查。尚未通过 Xcode 编译、XCTest 执行、模拟器运行或 iPad 真机 SSH 验证。不要把项目结构检查理解为 iOS 构建通过。

## 范围与限制

- 不在服务器部署服务，也不修改服务器配置。
- 只执行固定的只读系统信息命令，不提供任意终端命令输入。
- 尚无 Codex 聊天、任务、文件浏览、密钥导入和自动重连。
- iPadOS 挂起 App 后不保证 SSH 长连接存活；再次使用时可能需要重新连接。
- 通道状态检测不是主动心跳，网络黑洞可能要等系统 TCP 超时才会体现。
- 当前没有自定义 App 图标，使用开发阶段的默认图标；尚未准备上架资源。

## 工程维护

`scripts/generate_project.py` 用 Python 标准库生成已经纳入仓库的 Xcode 工程与共享 Scheme。新增 Swift 源文件后运行：

```sh
python3 scripts/generate_project.py
```

若在 Xcode 中手动修改工程配置，请同步修改生成脚本，以免再次生成时覆盖配置。工程暂不包含开发者 Team 或签名凭据；`work/` 和用户本地 Xcode 设置已加入忽略列表。

SSH 库：[Citadel](https://github.com/orlandos-nl/Citadel)，基于 SwiftNIO SSH。第三方代码按其各自许可证使用。
