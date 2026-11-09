import CoreBluetooth
import Foundation
import IOKit.hid

// 公开兼容驱动：私有包 `SayAllChromecast` 未编入时，由本文件向 `ChromecastFeatureIntegration`
// 提供同一组回调（连接状态、语音开始/结束、PCM、普通按键边沿）。
//
// 协议依据公开资料与开源实现 vibe-mote（MIT，Windows/Python）的真机记录：
// - 语音走 ATVV（服务 AB5E0001）：连接后向 AB5E0002 写一次 GET_CAPS，
//   AB5E0004 通知首字节 0x04 = 开始说话、0x00 = 结束；AB5E0003 通知为 16 kHz IMA ADPCM，
//   高 nibble 在前、跨帧连续。手势语义见 `ChromecastPublicVoiceArbiter`。
// - 按键走 HID Consumer Control：`[reportID] [usage_lo] [usage_hi]`，usage 为 0 表示全部松开。
//
// 本驱动不读取、不依赖任何第三方 App 的私有数据；只使用 CoreBluetooth 与 IOKit HID 公开 API。

// MARK: - 纯协议逻辑（可单测）

enum ChromecastPublicProtocol {
    /// Google 的 USB-IF 厂商 ID。Chromecast / Google TV 遥控器的 HID 设备都使用它。
    static let googleVendorID = 0x18D1
    /// 私有包实测过的 Chromecast with Google TV 遥控器产品 ID；运行时还会补入实际看到的产品 ID。
    static let knownProductIDs: Set<Int> = [0x9450]

    /// GET_CAPS（ATVV v1.0，16 kHz）。macOS 真机记录：本型号应答 `version=0x0100 codec=2 interaction=0x03`。
    /// （vibe-mote 在 Windows 上用 v0.4 握手；macOS 上维护者已验证 v1.0 路径，这里沿用后者。）
    static let getCapabilities = ATVVProtocol.getCapabilitiesV10

    static let consumerUsagePage: UInt64 = 0x0C
    /// ATVV v0.4 的带头音频帧长度与帧头长度。
    static let legacyFrameLength = 134
    static let legacyHeaderLength = 6

    /// Consumer Control usage → 按键（14/14，来自 vibe-mote 的受控采集）。
    /// 信源键以 macOS 真机为准（2026-11-09：数组下标 17 → `0x0089` Media Select TV），不是 vibe-mote 记录的 `0x0189`。
    static let usageToControl: [UInt16: ChromecastRemoteControl] = [
        0x019E: .power,
        0x0089: .input,
        0x0042: .up,
        0x0043: .down,
        0x0044: .left,
        0x0045: .right,
        0x0041: .select,
        0x0224: .back,
        0x0223: .home,
        0x00E9: .volumeUp,
        0x00EA: .volumeDown,
        0x00E2: .mute,
        0x0077: .youtube,
        0x0078: .netflix,
    ]

    /// 宿主原生按键屏蔽用的 HID 源（Consumer 页 usage）。
    static var nativeInputSources: [UInt64] {
        usageToControl.keys.sorted().map { consumerUsagePage << 32 | UInt64($0) }
    }

    /// 蓝牙名是否属于 Chromecast / Google TV 遥控器。与 `ForeignVoiceRemoteProduct` 使用同一份归一化，
    /// 小米链路拒绝的名字正是本链路接管的名字，避免两条链路抢同一台设备。
    static func isChromecastRemoteName(_ name: String?) -> Bool {
        guard let name else { return false }
        if ForeignVoiceRemoteProduct.isRejected(name: name) { return true }
        let normalized = name.lowercased()
        return normalized.contains("chromecast") || normalized.contains("google tv")
    }
}

/// IOKit element 级输入值 → 普通按键边沿（纯状态机，可单测）。
///
/// macOS 真机上本遥控器的 Consumer 报文是数组型：原始字节是下标（确定键 `01 07 00`）而不是 usage，
/// 不能自行按 16 位 usage 解析原始报文。IOKit 已按报告描述符把下标解析为 element 的 usage 与 0/1 值，
/// 这里只消费解析结果；数组容器本身（`usage=0xffffffff`）、其他页和表外 usage 一律忽略。
struct ChromecastPublicHIDValueTracker {
    struct Edge: Equatable {
        let usage: UInt16
        let phase: ChromecastRemoteControlPhase
    }

    private(set) var pressedUsages = Set<UInt16>()

    mutating func handle(usagePage: UInt32, usage: UInt32, value: Int) -> [Edge] {
        guard UInt64(usagePage) == ChromecastPublicProtocol.consumerUsagePage,
              usage <= UInt32(UInt16.max) else { return [] }
        let usage = UInt16(usage)
        guard ChromecastPublicProtocol.usageToControl[usage] != nil else { return [] }
        if value != 0 {
            guard pressedUsages.insert(usage).inserted else { return [] }
            return [Edge(usage: usage, phase: .began)]
        }
        guard pressedUsages.remove(usage) != nil else { return [] }
        return [Edge(usage: usage, phase: .ended)]
    }

    /// 清空按住状态，返回用于发送一次 cancelled 的代表 usage。
    mutating func cancelAll() -> UInt16? {
        let first = pressedUsages.sorted().first
        pressedUsages.removeAll()
        return first
    }
}

/// ATVV 控制通知 → 语音意图（纯状态机，可单测）。
///
/// 依据 Google Voice over BLE 1.0 与 `Testing/ChromecastHardwareInterface.md` 的 macOS 真机记录：
/// - 本型号协商 HTT（`interaction=0x03`）：物理按下 → `AUDIO_START(reason=0x03)`，远端自己开麦，
///   但只在有人声时推帧；松键 → `AUDIO_STOP`。HTT 流进行中**不得**补发 `MIC_OPEN`，否则远端改发
///   `stream=0` 的空流，此后一帧音频都不来。
/// - 「按一次说话」：第一次按下即开始识别；它松键之后由宿主写 `MIC_OPEN` 拿持续流
///   （`AUDIO_START(reason=0x00)`），期间定时 `MIC_EXTEND`；再按一次结束并写 `MIC_CLOSE`。
/// - 连按防抖：latch 后 0.6 秒内的再次按下不算「关」，避免「开了立刻关」。
struct ChromecastPublicVoiceArbiter {
    enum Action: Equatable {
        case startRecognition
        case stopRecognition(ChromecastVoiceEndReason)
        case write(Data)
        case resync(predictor: Int, stepIndex: Int)
        case log(String)
    }

    static let latchGraceInterval: TimeInterval = 0.6
    static let micOpen = Data([0x0C, 0x00])
    static let micClose = Data([0x0D, 0x00])
    static let micExtend = Data([0x0E, 0x00])

    private enum Gesture { case opening, closing, debounced, none }

    var mode: ChromecastVoiceMode = .toggle
    /// 宿主识别是否打开（用户可见的语音会话）。
    private(set) var recognitionOpen = false
    /// 宿主请求的持续流（MIC_OPEN）是否打开。
    private(set) var latched = false
    private var latchedAt: TimeInterval = 0
    /// 远端物理按住流（HTT/PTT）是否正在进行。
    private var physicalStreamActive = false
    private var gesture: Gesture = .none

    /// 宿主持续流打开期间需要定时续流。
    var needsExtend: Bool { recognitionOpen && latched }

    mutating func handleControl(_ data: Data, now: TimeInterval) -> [Action] {
        let bytes = Array(data)
        guard let opcode = bytes.first else { return [] }
        switch opcode {
        case 0x04:
            return audioStart(reason: bytes.count >= 2 ? bytes[1] : 0x03, now: now)
        case 0x00:
            return audioStop(now: now)
        case 0x08:
            // On-request 模型的 START_SEARCH：远端请求宿主开麦，语义等同「按一次」。
            guard !recognitionOpen else { return [.log("search action=none reason=already_open")] }
            recognitionOpen = true
            latched = true
            latchedAt = now
            return [.startRecognition, .write(Self.micOpen), .log("search action=latch")]
        case 0x0A:
            // v1.0 SYNC：[0x0A, codec, frame(2), predictor(2), stepIndex]。较短的 SYNC 不带预测值，忽略。
            guard bytes.count >= 7 else { return [] }
            let predictor = Int(Int16(bitPattern: UInt16(bytes[4]) << 8 | UInt16(bytes[5])))
            return [.resync(predictor: predictor, stepIndex: Int(bytes[6]))]
        case 0x0B:
            return []
        default:
            return [.log("control=unknown opcode=0x\(String(opcode, radix: 16)) bytes=\(bytes.count)")]
        }
    }

    private mutating func audioStart(reason: UInt8, now: TimeInterval) -> [Action] {
        guard reason != 0x00 else {
            // 宿主 MIC_OPEN 打开的持续流开始推送；不产生用户可见动作。
            return [.log("stream origin=host_requested")]
        }
        physicalStreamActive = true
        switch mode {
        case .hold:
            guard !recognitionOpen else { return [] }
            recognitionOpen = true
            gesture = .opening
            return [.startRecognition, .log("gesture=press action=start mode=hold")]
        case .toggle:
            if !recognitionOpen {
                recognitionOpen = true
                gesture = .opening
                return [.startRecognition, .log("gesture=press action=start mode=toggle")]
            }
            if latched, now - latchedAt < Self.latchGraceInterval {
                gesture = .debounced
                return [.log("gesture=press action=debounced mode=toggle")]
            }
            gesture = .closing
            var actions: [Action] = [.stopRecognition(.toggleSecondTap)]
            if latched { actions.append(.write(Self.micClose)) }
            recognitionOpen = false
            latched = false
            actions.append(.log("gesture=press action=stop mode=toggle"))
            return actions
        }
    }

    private mutating func audioStop(now: TimeInterval) -> [Action] {
        if physicalStreamActive {
            physicalStreamActive = false
            let current = gesture
            gesture = .none
            switch mode {
            case .hold:
                guard recognitionOpen else { return [] }
                recognitionOpen = false
                return [.stopRecognition(.holdRelease), .log("gesture=release action=stop mode=hold")]
            case .toggle:
                guard current == .opening, recognitionOpen, !latched else {
                    return [.log("gesture=release action=none mode=toggle")]
                }
                latched = true
                latchedAt = now
                return [.write(Self.micOpen), .log("gesture=release action=latch mode=toggle")]
            }
        }
        // 非物理流结束：宿主持续流被远端结束（超时等）。
        guard recognitionOpen, latched else { return [] }
        recognitionOpen = false
        latched = false
        return [.stopRecognition(.cancelled("remote_stream_ended")), .log("stream origin=host_requested result=ended_by_remote")]
    }

    /// 宿主侧结束会话（用户关闭语音、断链、停止）：返回需要写给远端的命令。
    mutating func hostEnded() -> [Action] {
        let actions: [Action] = latched ? [.write(Self.micClose)] : []
        recognitionOpen = false
        latched = false
        physicalStreamActive = false
        gesture = .none
        return actions
    }
}

// MARK: - 驱动

/// 公开 Chromecast 驱动。全部回调都在主线程发出，与私有包的约定一致。
final class ChromecastPublicRemoteDriver: NSObject {
    /// 运行时实际看到的 Google HID 产品 ID，供宿主原生按键屏蔽枚举系统服务。
    private(set) static var observedProductIDs = ChromecastPublicProtocol.knownProductIDs

    var onStatusChange: ((ChromecastLinkStatus) -> Void)?
    var onDeclaredCapabilitiesChange: ((ChromecastDeclaredCapabilities) -> Void)?
    var onVoiceStart: (() -> Void)?
    var onVoiceStop: ((ChromecastVoiceEndReason) -> Void)?
    var onControlEvent: ((ChromecastRemoteControlEvent) -> Void)?
    var onHIDPresenceChange: ((Bool) -> Void)?
    var onSamples: (([Int16], Int) -> Void)?
    var onLog: ((String) -> Void)?
    var prepareNativeInput: (([UInt64]) -> Bool)?
    var restoreNativeInput: (() -> Void)?

    /// 公开驱动支持「按住说话」与「按一次说话」（宿主 MIC_OPEN 持续流）。不读电池、无触摸面。
    static let declaredCapabilities: ChromecastDeclaredCapabilities = [
        .controlEdges, .voiceStream, .toggleVoiceGesture,
    ]
    /// 规范 4.6.1：远端音频传输超时 15 s~1 min，持续流期间按此间隔续流。
    private static let extendInterval: TimeInterval = 10

    private var running = false
    /// 遥控器应答的 ATVV 版本。v0.4 机型（实测 `version=0x4 frame=134`）不支持宿主持续流，只能按住说话。
    private var remoteProtocolVersion: UInt16 = 0x0100
    private var currentDeclaredCapabilities: ChromecastDeclaredCapabilities {
        Self.declaredCapabilities(protocolVersion: remoteProtocolVersion)
    }

    static func declaredCapabilities(protocolVersion: UInt16) -> ChromecastDeclaredCapabilities {
        protocolVersion >= 0x0100 ? declaredCapabilities : [.controlEdges, .voiceStream]
    }
    private var status: ChromecastLinkStatus = .disabled {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
            onDeclaredCapabilitiesChange?(status.isConnected ? currentDeclaredCapabilities : [])
        }
    }

    // ATVV / CoreBluetooth
    private static let serviceUUID = CBUUID(string: ATVVProtocol.serviceUUID)
    private static let transmitUUID = CBUUID(string: ATVVProtocol.transmitUUID)
    private static let audioUUID = CBUUID(string: ATVVProtocol.audioUUID)
    private static let controlUUID = CBUUID(string: ATVVProtocol.controlUUID)
    private static let retryDelay: TimeInterval = 3
    private static let scanWindow: TimeInterval = 8

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var transmit: CBCharacteristic?
    private var audio: CBCharacteristic?
    private var control: CBCharacteristic?
    private var retryWorkItem: DispatchWorkItem?
    private var loggedAdvertisingRemote = false
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var arbiter = ChromecastPublicVoiceArbiter()
    private var extendTimer: Timer?
    private let decoder = IMAADPCMDecoder()
    private var pendingResync: (predictor: Int, stepIndex: Int)?
    private var voiceGeneration = 0
    private var sessionFrameCount = 0
    private var sessionStartedAt: TimeInterval = 0

    // HID
    private var hidManager: IOHIDManager?
    private var hidDevices: [IOHIDDevice] = []
    private var valueTracker = ChromecastPublicHIDValueTracker()
    private var controlSequence = 0
    /// 只为每个表外 Consumer usage 记一次诊断，避免刷屏。
    private var loggedUnmappedUsages = Set<UInt32>()
    private var mappingEnabled = false
    private var nativeInputPrepared = false

    // MARK: 生命周期

    func start() {
        guard !running else { return }
        running = true
        log("CHROMECAST PUBLIC phase=started driver=public")
        startHID()
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else {
            beginDiscovery(reason: "start")
        }
        if status == .disabled || status == .unavailable { status = .searching }
    }

    func stop() {
        guard running else { return }
        running = false
        endVoiceIfNeeded(reason: .hostStop)
        cancelRetry()
        cancelScanTimeout()
        if let central, central.isScanning { central.stopScan() }
        if let peripheral, let central { central.cancelPeripheralConnection(peripheral) }
        resetPeripheral()
        stopHID()
        status = .disabled
        log("CHROMECAST PUBLIC phase=stopped")
    }

    func reconnect() {
        guard running else { return }
        log("CHROMECAST PUBLIC phase=reconnect reason=user")
        endVoiceIfNeeded(reason: .cancelled("reconnect"))
        if let peripheral, let central { central.cancelPeripheralConnection(peripheral) }
        resetPeripheral()
        beginDiscovery(reason: "user_reconnect")
        stopHID()
        startHID()
    }

    func setControlMappingEnabled(_ enabled: Bool) {
        guard mappingEnabled != enabled else { return }
        mappingEnabled = enabled
        log("CHROMECAST PUBLIC HID mapping=\(enabled)")
        if enabled {
            prepareNativeInputIfNeeded()
        } else if nativeInputPrepared {
            nativeInputPrepared = false
            restoreNativeInput?()
        }
    }

    var isHIDRemotePresent: Bool { !hidDevices.isEmpty }

    func setVoiceMode(_ requested: ChromecastVoiceMode) {
        let mode: ChromecastVoiceMode = remoteProtocolVersion < 0x0100 ? .hold : requested
        guard arbiter.mode != mode else { return }
        // 模式切换不打断进行中的会话：先由宿主结束，再在下次按下时按新模式解释。
        if arbiter.needsExtend || arbiter.recognitionOpen {
            perform(arbiter.hostEnded())
            finishVoice(reason: .cancelled("mode_changed"))
        }
        arbiter.mode = mode
        log("CHROMECAST PUBLIC VOICE mode=\(mode.rawValue)")
    }

    func notifyHostVoiceSessionEnded() {
        perform(arbiter.hostEnded())
        stopExtendTimer()
    }

    // MARK: 蓝牙发现与连接

    private func beginDiscovery(reason: String) {
        guard running, let central, central.state == .poweredOn, peripheral == nil else { return }
        cancelRetry()
        // 遥控器被系统 HID 连着时不广播：先看系统已连接的 ATVV 设备，再退回扫描。
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID])
        if let candidate = connected.first(where: { ChromecastPublicProtocol.isChromecastRemoteName($0.name) }) {
            log("CHROMECAST PUBLIC BLE source=system_connected reason=\(reason) candidates=\(connected.count)")
            connect(candidate)
            return
        }
        status = .searching
        log("CHROMECAST PUBLIC BLE phase=scanning reason=\(reason) system_candidates=\(connected.count)")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running, self.peripheral == nil else { return }
            self.central?.stopScan()
            self.log("CHROMECAST PUBLIC BLE phase=scan_timeout result=retrying")
            self.scheduleRetry(reason: "scan_timeout")
        }
        scanTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanWindow, execute: work)
    }

    private func connect(_ candidate: CBPeripheral) {
        guard let central else { return }
        cancelScanTimeout()
        if central.isScanning { central.stopScan() }
        peripheral = candidate
        candidate.delegate = self
        status = .connecting
        central.connect(candidate, options: nil)
    }

    private func resetPeripheral() {
        peripheral?.delegate = nil
        peripheral = nil
        transmit = nil
        audio = nil
        control = nil
        pendingResync = nil
        remoteProtocolVersion = 0x0100
        let mode = arbiter.mode
        arbiter = ChromecastPublicVoiceArbiter()
        arbiter.mode = mode
        stopExtendTimer()
    }

    private func scheduleRetry(reason: String) {
        guard running else { return }
        cancelRetry()
        let work = DispatchWorkItem { [weak self] in
            self?.beginDiscovery(reason: reason)
        }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay, execute: work)
    }

    private func cancelRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }

    private func cancelScanTimeout() {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
    }

    private func handleLinkLost(reason: String) {
        endVoiceIfNeeded(reason: .cancelled("link_unavailable"))
        resetPeripheral()
        if running {
            status = .disconnected
            scheduleRetry(reason: reason)
        }
    }

    private func subscribeIfReady(_ peripheral: CBPeripheral) {
        guard let audio, let control else { return }
        // 音频订阅必须先于控制订阅，避免丢掉起始帧。
        peripheral.setNotifyValue(true, for: audio)
        peripheral.setNotifyValue(true, for: control)
    }

    private func sendCapabilities(_ peripheral: CBPeripheral) {
        guard let transmit else {
            log("CHROMECAST PUBLIC ATVV caps=skipped reason=no_transmit")
            return
        }
        let type: CBCharacteristicWriteType = transmit.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        peripheral.writeValue(ChromecastPublicProtocol.getCapabilities, for: transmit, type: type)
        log("CHROMECAST PUBLIC ATVV caps=sent version=1.0")
    }

    // MARK: 语音

    private func handleControlNotification(_ data: Data) {
        if data.first == 0x0B, let caps = ATVVCapabilities.parse(data) {
            log(
                "CHROMECAST PUBLIC ATVV caps_response version=0x\(String(caps.version, radix: 16)) "
                    + "codec=\(caps.selectedCodec) interaction=0x\(String(caps.interaction, radix: 16)) "
                    + "frame=\(caps.frameSize)"
            )
            if !ATVVProtocol.supportsAudio(sampleRate: caps.sampleRate) {
                status = .unsupported(reason: "codec_8khz")
                return
            }
            if caps.version != remoteProtocolVersion {
                remoteProtocolVersion = caps.version
                if caps.version < 0x0100 {
                    // 旧协议：没有 MIC_OPEN 持续流，强制按住说话；宿主随能力变化同步生效模式。
                    arbiter.mode = .hold
                }
                if status.isConnected { onDeclaredCapabilitiesChange?(currentDeclaredCapabilities) }
            }
            return
        }
        if data.first == 0x04 || data.first == 0x00 {
            let reason = data.count >= 2 ? "0x" + String(data[data.startIndex + 1], radix: 16) : "none"
            log("CHROMECAST PUBLIC ATVV control=0x\(String(data[data.startIndex], radix: 16)) reason=\(reason)")
        }
        perform(arbiter.handleControl(data, now: ProcessInfo.processInfo.systemUptime))
    }

    private func perform(_ actions: [ChromecastPublicVoiceArbiter.Action]) {
        for action in actions {
            switch action {
            case .startRecognition:
                voiceGeneration &+= 1
                sessionFrameCount = 0
                sessionStartedAt = ProcessInfo.processInfo.systemUptime
                decoder.reset()
                pendingResync = nil
                log("CHROMECAST PUBLIC VOICE phase=started session=\(voiceGeneration) mode=\(arbiter.mode.rawValue)")
                // 同步回调：宿主必须在首帧音频到达前备好音频出口。
                onVoiceStart?()
            case .stopRecognition(let reason):
                stopExtendTimer()
                finishVoice(reason: reason)
            case .write(let command):
                write(command)
                if command == ChromecastPublicVoiceArbiter.micOpen { startExtendTimer() }
                if command == ChromecastPublicVoiceArbiter.micClose { stopExtendTimer() }
            case .resync(let predictor, let stepIndex):
                pendingResync = (predictor, stepIndex)
            case .log(let message):
                log("CHROMECAST PUBLIC VOICE \(message)")
            }
        }
    }

    private func write(_ command: Data) {
        guard let peripheral, let transmit, peripheral.state == .connected else {
            log("CHROMECAST PUBLIC ATVV write=skipped reason=not_connected bytes=\(command.map { String(format: "%02x", $0) }.joined())")
            return
        }
        let type: CBCharacteristicWriteType = transmit.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        peripheral.writeValue(command, for: transmit, type: type)
        log("CHROMECAST PUBLIC ATVV written bytes=\(command.map { String(format: "%02x", $0) }.joined())")
    }

    private func startExtendTimer() {
        stopExtendTimer()
        let timer = Timer(timeInterval: Self.extendInterval, repeats: true) { [weak self] _ in
            guard let self, self.arbiter.needsExtend else {
                self?.stopExtendTimer()
                return
            }
            self.write(ChromecastPublicVoiceArbiter.micExtend)
        }
        RunLoop.main.add(timer, forMode: .common)
        extendTimer = timer
    }

    private func stopExtendTimer() {
        extendTimer?.invalidate()
        extendTimer = nil
    }

    private func handleAudioNotification(_ data: Data) {
        guard arbiter.recognitionOpen, !data.isEmpty else { return }
        if let resync = pendingResync {
            decoder.reset(predictor: resync.predictor, stepIndex: resync.stepIndex)
            pendingResync = nil
        }
        if sessionFrameCount == 0 {
            log("CHROMECAST PUBLIC VOICE first_packet_bytes=\(data.count) protocol=0x\(String(remoteProtocolVersion, radix: 16))")
        }
        var adpcm = data
        if data.count == ChromecastPublicProtocol.legacyFrameLength {
            // ATVV v0.4 帧：seq(2) + id(1) + predictor(2) + stepIndex(1) + 128 字节 ADPCM。
            let header = Array(data.prefix(ChromecastPublicProtocol.legacyHeaderLength))
            let predictor = Int(Int16(bitPattern: UInt16(header[3]) << 8 | UInt16(header[4])))
            decoder.reset(predictor: predictor, stepIndex: Int(header[5]))
            adpcm = data.dropFirst(ChromecastPublicProtocol.legacyHeaderLength)
        }
        let decoded = decoder.decode(adpcm)
        // 与小米链路一致：只做平滑与限幅，用户音量在虚拟音频输出处统一施加。
        let samples = PCMPostprocessor.process(decoded, gainDB: 0)
        sessionFrameCount += 1
        onSamples?(samples, voiceGeneration)
    }

    private func finishVoice(reason: ChromecastVoiceEndReason) {
        let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - sessionStartedAt) * 1_000)
        log(
            "CHROMECAST PUBLIC VOICE phase=stopped session=\(voiceGeneration) "
                + "completion=\(reason.isNormal ? "normal" : "forced") reason=\(reason.logToken) "
                + "audio_packets=\(sessionFrameCount) duration_ms=\(elapsedMs)"
        )
        if reason.isNormal, sessionFrameCount == 0 {
            // 远端按人声门控推帧：没说话时零帧是正常的，但必须留证区分「没说话」与「链路没通」。
            log("CHROMECAST PUBLIC VOICE warning=no_audio_packets")
        }
        onVoiceStop?(reason)
    }

    private func endVoiceIfNeeded(reason: ChromecastVoiceEndReason) {
        guard arbiter.recognitionOpen else {
            perform(arbiter.hostEnded())
            return
        }
        perform(arbiter.hostEnded())
        stopExtendTimer()
        finishVoice(reason: reason)
    }

    // MARK: HID

    private func startHID() {
        guard hidManager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey as String: ChromecastPublicProtocol.googleVendorID] as CFDictionary
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, chromecastHIDDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, chromecastHIDDeviceRemoved, context)
        // 按键只取 IOKit 按报告描述符解析后的 element 值；本遥控器的原始报文是数组下标，不能直接解析。
        IOHIDManagerRegisterInputValueCallback(manager, chromecastHIDInputValue, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = manager
        log("CHROMECAST PUBLIC HID phase=manager_open result=\(result == kIOReturnSuccess ? "ok" : "failed") code=\(result)")
    }

    private func stopHID() {
        cancelPressedControls(reason: "hid_stopped")
        for device in hidDevices {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        let hadDevices = !hidDevices.isEmpty
        hidDevices.removeAll()
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil
        if nativeInputPrepared {
            nativeInputPrepared = false
            restoreNativeInput?()
        }
        if hadDevices { onHIDPresenceChange?(false) }
    }

    fileprivate func hidDeviceMatched(_ device: IOHIDDevice) {
        guard !hidDevices.contains(where: { $0 === device }) else { return }
        let productID = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        if let productID { Self.observedProductIDs.insert(productID) }
        let wasEmpty = hidDevices.isEmpty
        hidDevices.append(device)
        log(
            "CHROMECAST PUBLIC HID phase=device_matched product=0x"
                + String(productID ?? 0, radix: 16) + " devices=\(hidDevices.count)"
        )
        if wasEmpty { onHIDPresenceChange?(true) }
        if mappingEnabled { prepareNativeInputIfNeeded() }
    }

    fileprivate func hidDeviceRemoved(_ device: IOHIDDevice) {
        guard let index = hidDevices.firstIndex(where: { $0 === device }) else { return }
        hidDevices.remove(at: index)
        log("CHROMECAST PUBLIC HID phase=device_removed devices=\(hidDevices.count)")
        if hidDevices.isEmpty {
            cancelPressedControls(reason: "device_removed")
            if nativeInputPrepared {
                nativeInputPrepared = false
                restoreNativeInput?()
            }
            onHIDPresenceChange?(false)
        }
    }

    private func prepareNativeInputIfNeeded() {
        guard mappingEnabled, !hidDevices.isEmpty, !nativeInputPrepared else { return }
        nativeInputPrepared = prepareNativeInput?(ChromecastPublicProtocol.nativeInputSources) ?? false
        log("CHROMECAST PUBLIC HID native_input=\(nativeInputPrepared ? "neutralized" : "not_verified")")
    }

    fileprivate func hidInputValue(usagePage: UInt32, usage: UInt32, value: Int) {
        let edges = valueTracker.handle(usagePage: usagePage, usage: usage, value: value)
        if edges.isEmpty, UInt64(usagePage) == ChromecastPublicProtocol.consumerUsagePage,
           usage <= UInt32(UInt16.max), ChromecastPublicProtocol.usageToControl[UInt16(usage)] == nil,
           value != 0, loggedUnmappedUsages.insert(usage).inserted {
            // 只记 usage 编码，不含用户内容或设备身份；用于发现表外按键。
            log("CHROMECAST PUBLIC HID control phase=ignored reason=unmapped_usage usage=0x\(String(usage, radix: 16))")
        }
        for edge in edges {
            emitControl(edge.usage, phase: edge.phase)
        }
    }

    private func emitControl(_ usage: UInt16, phase: ChromecastRemoteControlPhase, reason: String? = nil) {
        guard let control = ChromecastPublicProtocol.usageToControl[usage] else { return }
        controlSequence &+= 1
        onControlEvent?(ChromecastRemoteControlEvent(
            control: control,
            phase: phase,
            sequence: controlSequence,
            cancellationReason: reason
        ))
    }

    private func cancelPressedControls(reason: String) {
        guard let usage = valueTracker.cancelAll() else { return }
        // 宿主收到 cancelled 会整体复位按键状态，发一次即可。
        emitControl(usage, phase: .cancelled, reason: reason)
    }

    private func log(_ message: String) {
        onLog?(message)
    }
}

// MARK: - CoreBluetooth

extension ChromecastPublicRemoteDriver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("CHROMECAST PUBLIC BLE central_state=\(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            beginDiscovery(reason: "powered_on")
        case .unauthorized:
            endVoiceIfNeeded(reason: .cancelled("bluetooth_unauthorized"))
            resetPeripheral()
            if running { status = .unauthorized }
        default:
            handleLinkLost(reason: "bluetooth_unavailable")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard running, self.peripheral == nil else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard ChromecastPublicProtocol.isChromecastRemoteName(advertisedName ?? peripheral.name) else { return }
        // 遥控器在广播 = 处于配对模式。此时连上去会和「系统设置 → 蓝牙」抢同一条连接，
        // 导致系统配对失败，且未绑定的连接约 30 秒后会被遥控器断开（2026-11-06 真机日志）。
        // 只记录，等系统配对完成后从「系统已连接」路径接管。
        guard !loggedAdvertisingRemote else { return }
        loggedAdvertisingRemote = true
        log("CHROMECAST PUBLIC BLE source=scan result=advertising_not_adopted hint=pair_in_system_settings")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        status = .connecting
        log("CHROMECAST PUBLIC BLE phase=connected discovering=atvv")
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        log("CHROMECAST PUBLIC BLE phase=connect_failed error=\(error.map { String(describing: type(of: $0)) } ?? "none")")
        handleLinkLost(reason: "connect_failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        log("CHROMECAST PUBLIC BLE phase=disconnected")
        handleLinkLost(reason: "disconnected")
    }
}

extension ChromecastPublicRemoteDriver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            // 只有通用服务、没有 ATVV：这支遥控器没有语音服务（兼容款批次差异），语音不可用。
            log("CHROMECAST PUBLIC ATVV phase=missing services=\(peripheral.services?.count ?? 0)")
            status = .unsupported(reason: "no_atvv_service")
            return
        }
        peripheral.discoverCharacteristics(
            [Self.transmitUUID, Self.audioUUID, Self.controlUUID],
            for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.transmitUUID: transmit = characteristic
            case Self.audioUUID: audio = characteristic
            case Self.controlUUID: control = characteristic
            default: break
            }
        }
        guard audio != nil, control != nil else {
            log("CHROMECAST PUBLIC ATVV phase=missing_characteristics")
            status = .unsupported(reason: "no_atvv_characteristics")
            return
        }
        subscribeIfReady(peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral === self.peripheral else { return }
        if let error {
            log("CHROMECAST PUBLIC ATVV notify=failed error=\(String(describing: type(of: error)))")
            return
        }
        guard characteristic.uuid == Self.controlUUID, characteristic.isNotifying else { return }
        sendCapabilities(peripheral)
        status = .connected(displayName: peripheral.name ?? "Chromecast Remote")
        log("CHROMECAST PUBLIC ATVV phase=ready")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.controlUUID: handleControlNotification(data)
        case Self.audioUUID: handleAudioNotification(data)
        default: break
        }
    }
}

// MARK: - IOKit C 回调

private func chromecastHIDDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<ChromecastPublicRemoteDriver>.fromOpaque(context).takeUnretainedValue().hidDeviceMatched(device)
}

private func chromecastHIDDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<ChromecastPublicRemoteDriver>.fromOpaque(context).takeUnretainedValue().hidDeviceRemoved(device)
}

private func chromecastHIDInputValue(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    let element = IOHIDValueGetElement(value)
    Unmanaged<ChromecastPublicRemoteDriver>.fromOpaque(context).takeUnretainedValue().hidInputValue(
        usagePage: IOHIDElementGetUsagePage(element),
        usage: IOHIDElementGetUsage(element),
        value: IOHIDValueGetIntegerValue(value)
    )
}
