# Chromecast 公开驱动丢弃全部普通按键

- 时间：2026-11-09
- 现场版本：本地实验分支 `feat/public-chromecast-remote` 的 `dist/SayAll.app`，`2.0.0 (270)`（ad-hoc，非分发候选）
- 影响范围：未编入私有包时的 `ChromecastPublicRemoteDriver`；Onboarding 遥控器页与键位映射

## 现象

Chromecast 语音遥控器已在系统蓝牙中连接，Onboarding 显示「所选遥控器已连接」，但「控制按键已收到」始终不完成；按确定键、方向键都没有反应，只有语音键被识别。

## 日志证据

- 原日志（pid 8021）：连接与 ATVV 正常，`ONBOARDING REMOTE_INPUT observed=voice` 9 次、`control_count=0`；全部历史日志中 `CHROMECAST ACTION` 与 `observed=control` 均为 0 条，说明按键在驱动内被静默丢弃。
- 加诊断日志复测（pid 13508）：每次按键都收到原始报文与 IOKit element 值，例如
  - 确定：`report id=1 len=3 bytes=010700 parsed=ignored`，同时 `value page=0xc usage=0x41 value=1`
  - 下：`010400` ↔ `usage=0x43`；返回：`010b00` ↔ `usage=0x224`；主页：`010a00` ↔ `usage=0x223`
  - 松开：`010000 parsed=released` ↔ 对应 usage `value=0`

## 根因

本遥控器在 macOS 上的 Consumer 报文是数组型，原始字节是下标而非 16 位 usage。旧实现 `pressedUsages(reportID:data:)` 把 `07 00` 当作 usage `0x0007` 查表，查不到就整条丢弃，因此从未发出按下边沿；只有全零松开报文被识别。usage 表本身正确，错误的是“原始字节即 usage”的假设，旧单测也基于该假设构造报文。

## 修复

- 移除原始报文解析与报文回调，改为 `IOHIDManagerRegisterInputValueCallback`，只消费 IOKit 按报告描述符解析后的 element usage 与值。
- 新增纯状态机 `ChromecastPublicHIDValueTracker`：仅 Consumer 页且在 14 键表内的 usage 生效；非 0 为按下、0 为抬起、重复值去重；忽略数组容器 `usage=0xffffffff`、其他页和表外 usage；取消时清空并发一次 cancelled。
- 表外 Consumer usage 首次按下记录 `CHROMECAST PUBLIC HID control phase=ignored reason=unmapped_usage usage=0x…`，只含 usage 编码。
- 不改 ATVV、语音键、音频和宿主映射逻辑。

## 补充：信源键编码错误（同日）

- 现象：修复后其余 13 键正常，信源键短按/按住都无动作。
- 证据：按键期间遥控器有 ATVV 按键标记，但无 `CHROMECAST ACTION`；临时诊断（已移除）记录到数组下标 17 对应 IOKit usage `page=0xc usage=0x89 value=1`，从未出现 `0x189`。
- 根因：usage 表沿用 vibe-mote 记录的 `0x0189`，macOS 真机实际为 `0x0089`（Media Select TV）。
- 修复：表项改为 `0x0089: .input`（原生屏蔽源随之更新），新增 `inputKeyUsesMacOSMediaSelectTVUsage` 回归测试。

## 验证

- 失败优先：新回归测试在修复前因缺少 `ChromecastPublicHIDValueTracker` 编译失败。
- `xcrun swift test --disable-keychain --filter "ChromecastPublicDriverTests|ChromecastIntegrationTests|ChromecastCapabilityContractTests|ChromecastFunctionKeyDriveTests"`：43 项通过。
- `xcrun swift test --disable-keychain`：1268 项、89 个 suite 全部通过。
- `CONFIGURATION=debug REQUIRE_SIRI_REMOTE_SIGNING=0 ./scripts/build-app.sh` 构建通过。
- 真机复测（pid 19416，2026-11-09）：Onboarding 遥控器页按上键即 `ONBOARDING REMOTE_INPUT observed=control control_count=1`，「控制按键已收到」完成并进入后续步骤；`CHROMECAST ACTION … button=up action=arrowUp`、`button=ok action=returnKey` 与物理键一致。
- 信源键修复后：完整 `swift test` 1269 项通过；真机复测（pid 25946）信源键短按/按住均触发动作，用户确认有反应。
- 未覆盖：其余键逐键映射、按住连发、断连取消复位尚未真机逐项验证；单元测试只证明按真机日志回放的状态机行为。
