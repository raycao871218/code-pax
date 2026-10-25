# Codex iPad

一个通过 SSH 控制远端 Linux Codex 的自用原生 iPad App。**0.2.0** 已接入真实 Codex App Server，可选择项目、聊天、处理审批和查看代码差异。

## 已实现

- SwiftUI 界面，支持 iPad 横竖屏、浅色和深色外观。
- 填写主机地址、端口、用户名和密码，执行真正的 SSH 密码认证。
- 首次连接显示 SHA256 主机指纹，由用户核对后保存到设备钥匙串；指纹变化时阻止连接。
- 登录后读取主机名、用户名、内核版本、Home 目录。
- 断开连接，以及检测已关闭的 SSH 通道。
- 保存地址和用户名；密码只保留在进程内存中，成功连接后清空输入框。
- 在 Home 范围内浏览项目目录，新建和切换会话。
- 发送任务，每两秒同步消息、命令结果和任务状态；命令详情可折叠。
- 处理命令、文件修改的一次性审批和澄清问题；额外权限请求目前只支持拒绝。
- 查看 Codex 提供的当前任务差异，区分增删行。
- 后台任务独立运行，断开 SSH 或关闭 App 后仍在服务器继续；重连后取回状态和历史。
- 为发送任务持久化操作 ID；结果不确定时使用相同 ID 重试，避免重复执行。
- 设置可选 HTTP/HTTPS 代理；无活动任务时可以从 App 重启后台。

## 结构

```text
iPad SwiftUI → SSH → Python CLI 客户端 → 私有 Unix socket
                                             ↓
                                   Python 后台 + SQLite
                                             ↓ stdio JSON-RPC
                                      Codex App Server
```

只需要服务器已有的 SSH、Python **3.9+** 和登录完成的 Codex CLI。后台使用 Python 标准库，不开放 TCP 端口，不复制服务器模型凭证。接口按 [OpenAI 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server) 接入，并在 Codex CLI **0.159.3** 上联调。

## 在 Mac 上运行

要求：Xcode 16 或更新版本；iPadOS 17 或更新版本。Windows 不能编译或签名 iPad App。

1. 在 Mac 上获取本仓库，打开 `CodexIPad.xcodeproj`。
2. 等待 Xcode 下载 Swift Package 依赖。Citadel 固定为 **0.12.1**，无需 CocoaPods 或 XcodeGen。
3. 选择 **CodexIPad** target → **Signing & Capabilities**，选择自己的开发者 Team；如有冲突，修改 Bundle Identifier。
4. 选择 iPad 模拟器或已配对的真实 iPad，运行。
5. 输入服务器地址、SSH 端口、用户名和该服务器的密码。
6. 首次连接先核对指纹，再点击“信任并连接”。看到系统信息即连接成功。
7. 切换到“工作区”。如果服务器需要代理，在 HTTP 代理中填写地址，例如 NAS 的 `http://10.10.0.66:7890`，然后点击“准备 Codex 工作区”。
8. 点击“新建项目会话”，浏览到项目目录，在该目录创建会话，然后发送任务。

“准备工作区”会把 App 内置的 `bridge.py` 写到服务器 `~/.local/share/codex-ipad/`，并以当前 SSH 用户启动后台。无需 sudo，不改动全局 Codex 配置。该目录包含历史数据库和运行日志，权限为 0700，socket 为 0600。代理环境只应用于后台进程；更改代理后，在任务都结束时点击“重启 Codex 后台”。

服务器重启会中断活动任务。重新准备工作区后保留历史并显示中断状态，发送新消息时用 `thread/resume` 继续会话，不会自动重跑旧任务。App 断网后需要重新建立 SSH 连接并再次准备工作区，现有后台会被复用。

默认地址 `10.10.0.172` 是局域网地址。外出时请先连接 ZeroTier，并改用服务器实际的 ZeroTier IP 或可达域名。第一次访问局域网时请允许系统弹出的本地网络权限。

在服务器上核对 SSH 主机指纹（只读取公钥）：

```sh
for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key" -E sha256; done
```

将 App 显示的 SHA256 指纹与对应的服务器公钥进行比较。第一版只支持密码认证；如果服务器只接受私钥，请先不要修改服务器安全设置，后续增加 App 的私钥认证功能即可。认证不支持键盘交互或双因素登录。

## 验证

项目包含输入校验、OpenSSH 指纹格式、JSON 协议和 shell 参数转义的 XCTest。在 Xcode 中按 **⌘U** 运行；测试不需要服务器密码。

后台测试（不访问模型，不修改业务项目）：

```sh
python3 -m unittest discover -s backend -v
```

本次验证：

- 14 项后台测试在 Linux 上全部通过，包括重复发送去重、未知结果防重放、审批任务绑定、过期审批拒绝、安全重启、停止状态、问题回答、权限拒绝、历史恢复与符号链接越界。
- 在 172 的独立 `/tmp` 测试项目中，真实完成了会话创建、任务发送、回复、命令审批、文件修改审批和 diff 读取。测试使用 NAS Mihomo 代理；未修改业务项目或全局 Codex 配置。
- 独立客户端重新连接后台后能读取已完成任务的历史和状态。
- 新增及修改的 Swift 文件通过语法解析检查；工程和资源结构检查通过。

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

0.1 的打包已由用户确认。0.2 的新增 iOS 代码尚未在本机进行 Xcode 编译、XCTest 执行或 iPad 真机端到端验证；以上服务器测试不等于 App 构建通过。更新后请在 Mac 上重新构建并运行。

## 范围与限制

- 第一版的目录浏览默认限制在 SSH 用户 Home 内，可在服务器手动启动 `python3 bridge.py ensure --root /your/projects` 指定其他根目录。该限制约束 App 目录选择，不是 SSH 账号权限隔离。
- Codex 使用 `workspace-write` 沙箱及 `untrusted` 审批策略，审批交给用户。第一版不提供会话级放行或自动批准。
- 尚无私钥导入、自动 SSH 重连、模型切换、推送通知和文件编辑器。
- 当前会话界面显示最近 40 条消息，单条最多约 12000 字符，过长内容会标明截断；早期消息保留在后台数据库。不是完整历史浏览器。
- 实时展示通过定时同步完成，延迟约两秒；切后台暂停同步，服务器任务继续。
- 未实现的 MCP 交互请求会明确拒绝，不会自动授权。
- 对不确定的发送结果不要直接创建一个新请求。先刷新状态，或用“重试”复用操作 ID。只有核实服务器状态后才清除本机重试记录。
- 通道状态检测不是主动心跳，网络黑洞可能要等系统 TCP 超时才会体现。
- 当前没有自定义 App 图标，使用开发阶段的默认图标；尚未准备上架资源。

## 工程维护

`scripts/generate_project.py` 用 Python 标准库生成已经纳入仓库的 Xcode 工程与共享 Scheme。新增 Swift 源文件后运行：

```sh
python3 scripts/generate_project.py
```

若在 Xcode 中手动修改工程配置，请同步修改生成脚本，以免再次生成时覆盖配置。工程暂不包含开发者 Team 或签名凭据；`work/` 和用户本地 Xcode 设置已加入忽略列表。

SSH 库：[Citadel](https://github.com/orlandos-nl/Citadel)，基于 SwiftNIO SSH。第三方代码按其各自许可证使用。
