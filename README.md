# Google 遥控器语音输入 for Mac

[English](README.en.md)

把 **Chromecast with Google TV 语音遥控器**（蓝牙名「Chromecast Remote」）变成 Mac 的无线麦克风和遥控器：按住语音键说话，文字直接进入豆包输入法等语音工具；其余按键可以映射成方向键、回车、返回、音量等 Mac 操作。

> **这是社区修改版，不是官方版本。** 本仓库 Fork 自开源项目 [无线麦 SayAll](https://github.com/HD838A/remote-mic-app)（`GPL-3.0-only`），在没有官方私有组件的公开构建里补上了 Google 遥控器支持。它与 SayAll 官方、Google 均无隶属、授权或背书关系；「Google」「Chromecast」「Google TV」是其各自所有者的商标，这里只用来说明兼容的硬件。

## 能做什么

- **按住说话**：按住遥控器语音键说话，松开结束。识别后的文字由你的语音工具写进当前输入框。
- **按一次说话**：也可以切换成按一下开始、再按一下结束。
- **14 个普通按键**：方向键、确定、返回、主页、电源、音量加减、静音、信源、YouTube、Netflix，可以在「按键映射」里分别设置动作。
- **首次使用向导**：一步步完成权限授予、遥控器连接、按键检查和语音测试。
- 只用 macOS 公开的蓝牙和 HID 接口，不读取任何第三方 App 的私有数据。

## 支持的硬件与系统

| 项目 | 要求 |
| --- | --- |
| 遥控器 | Chromecast with Google TV 语音遥控器（系统蓝牙里显示为「Chromecast Remote」） |
| Mac | Apple 芯片（M 系列），macOS 14 或更新版本 |
| 语音工具 | 豆包输入法（已实测）；其他能用 Fn 键触发语音、并能选择麦克风的工具理论上可用 |
| 虚拟麦克风 | `MiRemoteV 2ch` 音频设备（见下方「安装与首次设置」） |

## 下载

到本仓库的 [Releases](../../releases) 页面下载最新的 `.dmg`。

> 目前还没有发布安装包，发布后会出现在 Releases 页面。

安装包是**社区自行构建的版本，没有经过 Apple 公证**，第一次打开时 macOS 会拦截：

1. 打开 `.dmg`，把 App 拖进「应用程序」文件夹。
2. 在「应用程序」里**右键点 App → 打开**，在弹出的对话框里再点一次「打开」。
3. 如果仍被拦截：打开「系统设置 → 隐私与安全性」，在页面底部点「仍要打开」。

如果你更放心自己编译，可以直接从本仓库源码构建（见下方「从源码构建」）。

## 安装与首次设置

1. **配对遥控器**：打开「系统设置 → 蓝牙」，同时按住遥控器的「返回」和「主页」键，直到指示灯闪烁，然后连接「Chromecast Remote」。
2. **安装虚拟麦克风 `MiRemoteV 2ch`**：遥控器的声音要通过这个虚拟音频设备送给语音工具。社区版安装包暂不包含它；如果你的 Mac 上还没有，需要从源码构建安装（`scripts/build-doubao-driver.sh`）。
3. **授予权限**：首次打开 App 时，按向导授予「蓝牙」「输入监控」「辅助功能」三项权限，然后完全退出并重新打开 App。
4. **跟着向导走**：选择 Chromecast 遥控器 → 按一下确定键或方向键确认连接 → 选择语音工具 → 说一句话测试。

## 配合豆包输入法

在豆包输入法的设置里：

- 语音快捷键使用 **Fn**；
- **按住说话**：App 里选「按住说话」，豆包使用「长按模式」；
- **按一次说话**：App 里选「按一次说话」，豆包使用「免按模式」；
- 开启「全局唤起语音」；
- 麦克风选择 **MiRemoteV 2ch**。

如果按住语音键时豆包的录音浮窗没有出现，几乎都是豆包的快捷键或模式没设对，先检查上面几项。

## 已知限制

- 安装包没有经过 Apple 公证，首次打开需要手动允许。
- 左、右、YouTube、Netflix 键的映射，以及长按连发、断开蓝牙后的按键复位，还没有在真机上逐项验证。
- 只支持 Apple 芯片的 Mac；Intel Mac 未测试。
- 社区版没有官方的崩溃诊断上报，也没有官方的自动更新。

遇到问题欢迎在本仓库提 [Issue](../../issues)。附上 App「文件 → 打开日志所在文件夹」里的日志，会更容易排查。

## 从源码构建

需要安装 Xcode。

```bash
git clone https://github.com/itinglight/remote-mic-app.git
```

```bash
cd remote-mic-app
```

```bash
CONFIGURATION=release SAYALL_PRIVATE_PLATFORM_MODE=public REQUIRE_SIRI_REMOTE_SIGNING=0 ./scripts/build-app.sh
```

构建产物在 `dist/SayAll.app`（ad-hoc 签名，只适合自己使用）。

## 与官方版本的区别

| | 官方无线麦 SayAll | 本社区修改版 |
| --- | --- | --- |
| Google 遥控器 | 依赖官方私有组件 | 公开源码实现（`Sources/RemoteMic/ChromecastPublicRemoteDriver.swift`） |
| 小米、苹果遥控器 | 支持 | 未针对它们测试，请使用官方版本 |
| 签名与公证 | Developer ID 签名并经 Apple 公证 | 未公证 |
| 下载 | [sayall.app](https://sayall.app/) | 本仓库 Releases |

如果你用的是小米蓝牙遥控器或苹果遥控器，请直接使用 [官方版本](https://sayall.app/)。

## 许可与来源

- 软件代码采用 `GPL-3.0-only` 许可，见 [LICENSE.md](LICENSE.md)。本仓库是对 [HD838A/remote-mic-app](https://github.com/HD838A/remote-mic-app) 的修改版本，修改内容见本仓库的提交记录。
- 官方 App Logo 和 App Icon 不属于 GPL 授权范围，Fork 不得将其用作自己的品牌标识，见 [LOGO-LICENSE.md](LOGO-LICENSE.md)。
- Google 遥控器协议参考了开源项目 vibe-mote（MIT）的公开记录，并以 macOS 真机实测为准。
- 完整版权与第三方信息见 [COPYRIGHT.md](COPYRIGHT.md) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 开发者文档

开发者和贡献者请从 [项目文档导航](DOCUMENTATION.md) 开始。
