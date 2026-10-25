# Codex iPad

一个通过 SSH 控制远端 Linux Codex 的自用原生 iPad App。**0.3.0** 支持 CLI 历史会话、项目分组、模型选择、多服务器和可选的钥匙串密码保存。

## 已实现

- SwiftUI 界面，支持 iPad 横竖屏、浅色和深色外观。
- 填写主机地址、端口、用户名和密码，执行真正的 SSH 密码认证。
- 首次连接显示 SHA256 主机指纹，由用户核对后保存到设备钥匙串；指纹变化时阻止连接。
- 登录后读取主机名、用户名、内核版本、Home 目录。
- 断开连接，以及检测已关闭的 SSH 通道。
- 保存多台服务器的名称、地址、端口和用户名，一次连接一台；切换时关闭旧 SSH 连接，后台任务继续执行。
- 可选择“记住密码”，密码存入本机钥匙串，绑定服务器配置、地址、端口和用户名，不写入 UserDefaults、不进行 iCloud 同步。关闭记住密码或删除服务器会移除相应凭据。
- 在 Home 范围内浏览项目目录，新建和切换会话。
- 发送任务，每两秒同步消息、命令结果和任务状态；命令详情可折叠。
- 处理命令、文件修改的一次性审批和澄清问题；额外权限请求目前只支持拒绝。
- 查看 Codex 提供的当前任务差异，区分增删行。
- 后台任务独立运行，断开 SSH 或关闭 App 后仍在服务器继续；重连后取回状态和历史。
- 为发送任务持久化操作 ID；结果不确定时使用相同 ID 重试，避免重复执行。
- 设置可选 HTTP/HTTPS 代理；无活动任务时可以从 App 重启后台。
- 同步同一服务器、同一 SSH 用户及同一 Codex Home 下的未归档 CLI / VS Code / exec / App Server 历史会话，按工作目录归入项目；支持分页导入和搜索。
- 添加暂时没有会话的项目；相同目录使用一个项目分组，目录不同的同名项目会显示完整路径。
- 查看历史不会自动恢复或执行任务。发送新消息时恢复原 thread，正在外部 CLI 中执行的任务只读显示。
- 历史窗口支持按页浏览更早消息。模型列表及可用推理强度从服务器读取，选择后用于下一次任务，支持沿用原会话或服务器默认设置。

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
   可填写服务器名称并勾选“记住这台服务器的密码”，再保存设置。顶部列表用于切换服务器，“添加服务器”可保存其他 IP 或域名。
6. 首次连接先核对指纹，再点击“信任并连接”。看到系统信息即连接成功。
7. 切换到“工作区”。如果服务器需要代理，在 HTTP 代理中填写地址，例如 NAS 的 `http://10.10.0.66:7890`，然后点击“准备 Codex 工作区”。
8. 工作区会自动同步一页 CLI 历史。展开项目即可选择历史会话；点“加载更多历史会话”继续分页导入。
9. 点“添加项目 / 新建会话”，可单独保存项目，也可直接创建新会话。侧栏可选择模型和推理强度，设置对下一次发送生效。

### 从 0.2 升级

先在旧后台仍运行时连接并准备工作区。App 会识别旧协议并保留原有聊天、审批、停止功能；完成原来的任务后，点击“重启 Codex 后台”。新后台启动后才会启用 CLI 历史同步和模型选择，不会为升级强制结束正在运行的任务。旧单服务器配置会迁移，多台服务器的代理与会话选择分别保存。

“准备工作区”会把 App 内置的 `bridge.py` 写到服务器 `~/.local/share/codex-ipad/`，并以当前 SSH 用户启动后台。无需 sudo，不改动全局 Codex 配置。该目录包含历史数据库和运行日志，权限为 0700，socket 为 0600。代理环境只应用于后台进程；更改代理后，在任务都结束时点击“重启 Codex 后台”。

服务器重启会中断活动任务。重新准备工作区后保留历史并显示中断状态，发送新消息时用 `thread/resume` 继续会话，不会自动重跑旧任务。App 断网后需要重新建立 SSH 连接并再次准备工作区，现有后台会被复用。

默认地址 `10.10.0.172` 是局域网地址。外出时请先连接 ZeroTier，并改用服务器实际的 ZeroTier IP 或可达域名。第一次访问局域网时请允许系统弹出的本地网络权限。

在服务器上核对 SSH 主机指纹（只读取公钥）：

```sh
for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key" -E sha256; done
```

将 App 显示的 SHA256 指纹与对应的服务器公钥进行比较。第一版只支持密码认证；如果服务器只接受私钥，请先不要修改服务器安全设置，后续增加 App 的私钥认证功能即可。认证不支持键盘交互或双因素登录。

## 验证

项目包含输入校验、旧连接配置迁移、密码凭据绑定范围、OpenSSH 指纹格式、JSON 协议和 shell 参数转义的 XCTest。在 Xcode 中按 **⌘U** 运行；测试不需要服务器密码。钥匙串读写和多服务器切换仍需 iPad 真机验证。

后台测试（不访问模型，不修改业务项目）：

```sh
python3 -m unittest discover -s backend -v
```

本次验证：

- 21 项后台测试在 Linux 上全部通过，包括历史目录过滤、只读浏览、历史分页、外部运行会话保护、原会话续聊、模型分页和推理强度校验、空项目持久化，以及之前的审批和断线保护。
- 在 172 的独立 `/tmp` 测试项目中，真实完成了会话创建、任务发送、回复、命令审批、文件修改审批和 diff 读取。测试使用 NAS Mihomo 代理；未修改业务项目或全局 Codex 配置。
- 独立客户端重新连接后台后能读取已完成任务的历史和状态。
- 在独立 `/tmp` 项目中真实运行 Codex CLI 创建会话，再通过新后台导入并只读浏览，随后在同一个 thread 上指定模型和推理强度继续对话，全部通过。
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

之前版本的打包已由用户确认。0.3 的新增 iOS 代码尚未在本机进行 Xcode 编译、XCTest 执行或 iPad 真机端到端验证；以上服务器测试不等于 App 构建通过。更新后请在 Mac 上重新构建并运行。

## 范围与限制

- 第一版的目录浏览默认限制在 SSH 用户 Home 内，可在服务器手动启动 `python3 bridge.py ensure --root /your/projects` 指定其他根目录。该限制约束 App 目录选择，不是 SSH 账号权限隔离。
- Codex 使用 `workspace-write` 沙箱及 `untrusted` 审批策略，审批交给用户。第一版不提供会话级放行或自动批准。
- 尚无私钥导入、自动 SSH 重连、推送通知和文件编辑器。
- 当前聊天显示最近 40 条消息；点右上角历史按钮分页浏览早期消息。单条最多约 12000 字符，过长会标明截断。侧栏最多显示最近 1000 条已同步会话，归档会话暂不显示。
- 历史导入只包含项目目录仍存在且位于工作根目录内的会话。使用不同 SSH 用户或不同 Codex Home 时，历史也不同。
- 外部 CLI 仍在运行的会话不会自动接管。请先在 CLI 完成当前任务，再刷新后续聊，避免两个客户端同时写入同一会话。
- 模型列表来自服务器目录，并不保证每个模型都具有当前账号的使用权限；实际执行失败会如实显示，不会静默切换到其他模型。
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
