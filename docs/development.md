# 开发、构建与验证

回到 [项目介绍](../README.md)。当前工程与 Scheme 为 `CodePax`，App 版本为 **0.14.1（Build 29）**。

## 工程结构

```text
CodePax/                     SwiftUI 客户端、SSH 连接、终端和资源
CodePaxTests/                模型、交互、连接恢复、素材与终端测试
CodePax.xcodeproj/           Xcode 工程、共享 Scheme 与依赖锁定文件
backend/bridge.py           随 App 打包并部署到远端的 Python 桥接脚本
backend/test_bridge.py      后台回归测试
design/brand/               默认角色原画、动作图、来源和提示词
docs/                      使用引导
scripts/                   工程与图像资源生成工具
```

当前验证环境为 **Xcode 27.1（27A9275）**，最低目标系统为 iPadOS 17。工程的 Swift 源码使用 Swift 5 语言模式，但锁定的依赖含更新的 Swift 工具链要求；不能据此认定 Xcode 16 一定可用。

## 构建与测试

先解析依赖，再选择可用 iPad 模拟器：

```sh
xcodebuild -resolvePackageDependencies -project CodePax.xcodeproj -scheme CodePax
xcodebuild -showdestinations -project CodePax.xcodeproj -scheme CodePax
```

Apple Silicon Mac 上，将 `YOUR_SIMULATOR_ID` 替换为上一步列出的 iPad 模拟器 ID：

```sh
xcodebuild -project CodePax.xcodeproj -scheme CodePax \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build

xcodebuild -project CodePax.xcodeproj -scheme CodePax \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ARCHS=arm64 test
```

上述命令按已验证的 Apple Silicon 环境编写。也可以在 Xcode 中选中 iPad 模拟器，按 ⌘U 运行测试。

真机签名由各开发者选择自己的 Team；项目不固定个人签名团队。安装真机的基本命令如下，需先配置可用的签名：

```sh
xcodebuild -project CodePax.xcodeproj -scheme CodePax \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=YOUR_TEAM_ID build
```

Python 后台测试不访问模型，也不需要服务器凭据：

```sh
python3 -m unittest discover -s backend -p 'test_*.py' -v
```

## 已有验证

0.14.1 工程改名后验证通过：

- **49 项 iOS 测试**：包括模型与协议、当前页面换肤与换色、消息状态、草稿与连接恢复、附件与 Markdown 文件、头像持久化、GIF / APNG 时序、四帧拆分，以及交互终端。
- **60 项后台测试**：包括历史、幂等发送、权限、附件与文件访问、内容分页、后台升级等。
- **真机签名构建与 iPad 安装成功**。运行测试与成功安装不等于已覆盖每种设备、网络或真实服务器环境。

终端集成测试使用本机回环地址上临时启动的 SSH 服务，核对中文与控制键回显、PTY 尺寸变化，以及关闭终端后共享 SSH 仍能执行其他命令。它不连接个人业务服务器。

## 工程与资源生成

工程文件已提交，普通使用者无需重新生成。新增 Swift 源文件或修改公共构建配置后，运行：

```sh
python3 scripts/generate_project.py
```

该脚本使用 Python 标准库；重新生成会覆盖工程和 Scheme，因此在 Xcode 手动调整的公共配置也应同步到生成脚本。依赖锁定文件应与版本变动一起维护。

重新打包默认角色资源：

```sh
swift scripts/generate_icon.swift
swift scripts/package_thinking_frames.swift
```

第一个脚本从已选定原画生成 1024px 桌面图标和 512px 应用内头像；第二个拆分默认四帧动作图，并生成循环预览。它们处理仓库内的默认资源，与用户在 App 中导入的自定义素材相互独立。

`work/`、DerivedData、用户本地 Xcode 设置和签名材料已在 `.gitignore` 排除。
