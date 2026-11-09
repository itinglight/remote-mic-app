import Foundation
import Testing
@testable import RemoteMic

@Suite("Chromecast public driver")
struct ChromecastPublicDriverTests {
    // MARK: - HID 报文

    @Test func usageTableCoversEveryOrdinaryControlExactlyOnce() {
        let mapped = Set(ChromecastPublicProtocol.usageToControl.values)
        #expect(mapped == Set(ChromecastRemoteControl.allCases))
        #expect(ChromecastPublicProtocol.usageToControl.count == ChromecastRemoteControl.allCases.count)
    }

    // macOS 真机（2026-11-09）：Consumer 报文是数组型，原始字节里是下标而不是 usage，
    // 例如确定键为 `01 07 00`。IOKit 按报告描述符解析后给出 element 级的 usage 与 0/1 值，
    // 还会对数组容器本身给出 `usage=0xffffffff` 的值。下面按真机日志顺序回放。
    private static let arrayContainerUsage: UInt32 = 0xFFFF_FFFF

    @Test func elementValuesFromArrayReportProducePressAndRelease() {
        var tracker = ChromecastPublicHIDValueTracker()
        var edges: [ChromecastPublicHIDValueTracker.Edge] = []
        // 按下确定键：容器(7) → select=1 → 容器(7)
        edges += tracker.handle(usagePage: 0x0C, usage: Self.arrayContainerUsage, value: 7)
        edges += tracker.handle(usagePage: 0x0C, usage: 0x41, value: 1)
        edges += tracker.handle(usagePage: 0x0C, usage: Self.arrayContainerUsage, value: 7)
        // 松开：容器(0) → select=0 → 容器(0)
        edges += tracker.handle(usagePage: 0x0C, usage: Self.arrayContainerUsage, value: 0)
        edges += tracker.handle(usagePage: 0x0C, usage: 0x41, value: 0)
        edges += tracker.handle(usagePage: 0x0C, usage: Self.arrayContainerUsage, value: 0)
        #expect(edges == [
            .init(usage: 0x41, phase: .began),
            .init(usage: 0x41, phase: .ended),
        ])
    }

    @Test func realDeviceKeySequenceMapsToPhysicalControls() {
        var tracker = ChromecastPublicHIDValueTracker()
        var began: [ChromecastRemoteControl] = []
        for usage: UInt32 in [0x43, 0x224, 0x223] {
            for edge in tracker.handle(usagePage: 0x0C, usage: usage, value: 1) where edge.phase == .began {
                began.append(ChromecastPublicProtocol.usageToControl[edge.usage]!)
            }
            _ = tracker.handle(usagePage: 0x0C, usage: usage, value: 0)
        }
        #expect(began == [.down, .back, .home])
    }

    @Test func inputKeyUsesMacOSMediaSelectTVUsage() {
        // macOS 真机：信源键为数组下标 17，IOKit 解析为 Consumer `0x0089`；`0x0189` 从未出现。
        var tracker = ChromecastPublicHIDValueTracker()
        let began = tracker.handle(usagePage: 0x0C, usage: 0x89, value: 1)
        #expect(began == [.init(usage: 0x89, phase: .began)])
        #expect(ChromecastPublicProtocol.usageToControl[0x89] == .input)
        #expect(tracker.handle(usagePage: 0x0C, usage: 0x89, value: 0) == [.init(usage: 0x89, phase: .ended)])
        #expect(tracker.handle(usagePage: 0x0C, usage: 0x189, value: 1).isEmpty)
    }

    @Test func repeatedValuesDoNotDuplicateEdges() {
        var tracker = ChromecastPublicHIDValueTracker()
        #expect(tracker.handle(usagePage: 0x0C, usage: 0xE9, value: 1).count == 1)
        #expect(tracker.handle(usagePage: 0x0C, usage: 0xE9, value: 1).isEmpty)
        #expect(tracker.handle(usagePage: 0x0C, usage: 0xE9, value: 0).count == 1)
        #expect(tracker.handle(usagePage: 0x0C, usage: 0xE9, value: 0).isEmpty)
    }

    @Test func ignoresOtherPagesUnknownUsagesAndArrayContainer() {
        var tracker = ChromecastPublicHIDValueTracker()
        #expect(tracker.handle(usagePage: 0x07, usage: 0x28, value: 1).isEmpty)
        #expect(tracker.handle(usagePage: 0x0C, usage: 0xCD, value: 1).isEmpty)
        #expect(tracker.handle(usagePage: 0x0C, usage: Self.arrayContainerUsage, value: 7).isEmpty)
        #expect(tracker.pressedUsages.isEmpty)
    }

    @Test func cancelClearsPressedUsagesOnce() {
        var tracker = ChromecastPublicHIDValueTracker()
        _ = tracker.handle(usagePage: 0x0C, usage: 0x42, value: 1)
        _ = tracker.handle(usagePage: 0x0C, usage: 0x45, value: 1)
        #expect(tracker.cancelAll() == 0x42)
        #expect(tracker.pressedUsages.isEmpty)
        #expect(tracker.cancelAll() == nil)
        // 取消后同一键的松开值不应再产生边沿。
        #expect(tracker.handle(usagePage: 0x0C, usage: 0x42, value: 0).isEmpty)
    }

    @Test func nativeInputSourcesUseConsumerPage() {
        let sources = ChromecastPublicProtocol.nativeInputSources
        #expect(sources.count == 14)
        #expect(sources.allSatisfy { $0 >> 32 == 0x0C })
        #expect(sources.contains(0x0C << 32 | 0x00E9))
    }

    @Test func recognizesChromecastNamesThatXiaomiRejects() {
        #expect(ChromecastPublicProtocol.isChromecastRemoteName("Chromecast Remote"))
        #expect(ChromecastPublicProtocol.isChromecastRemoteName("Chromecast"))
        #expect(ChromecastPublicProtocol.isChromecastRemoteName("Google TV Remote"))
        #expect(!ChromecastPublicProtocol.isChromecastRemoteName("小米蓝牙语音遥控器"))
        #expect(!ChromecastPublicProtocol.isChromecastRemoteName(nil))
    }

    // MARK: - 语音手势

    private let press = Data([0x04, 0x03, 0x02, 0x0E])      // AUDIO_START reason=HTT
    private let release = Data([0x00, 0x02])                // AUDIO_STOP
    private let hostStream = Data([0x04, 0x00, 0x02, 0x00]) // AUDIO_START reason=MIC_OPEN

    @Test func getCapabilitiesUsesVersionOne() {
        #expect(ChromecastPublicProtocol.getCapabilities == Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03]))
    }

    @Test func holdModeStartsOnPressAndStopsOnRelease() {
        var arbiter = ChromecastPublicVoiceArbiter()
        arbiter.mode = .hold
        #expect(arbiter.handleControl(press, now: 0).contains(.startRecognition))
        // 重复的开始不得产生第二次用户可见动作。
        #expect(!arbiter.handleControl(press, now: 0.1).contains(.startRecognition))
        let stop = arbiter.handleControl(release, now: 1)
        #expect(stop.contains(.stopRecognition(.holdRelease)))
        // HTT 下不得补发 MIC_OPEN。
        #expect(!stop.contains(.write(ChromecastPublicVoiceArbiter.micOpen)))
        #expect(!arbiter.recognitionOpen)
    }

    @Test func toggleModeLatchesAfterFirstReleaseAndClosesOnSecondPress() {
        var arbiter = ChromecastPublicVoiceArbiter()
        arbiter.mode = .toggle
        let first = arbiter.handleControl(press, now: 0)
        #expect(first.contains(.startRecognition))
        // 物理流进行中不得写 MIC_OPEN。
        #expect(!first.contains(.write(ChromecastPublicVoiceArbiter.micOpen)))
        let latch = arbiter.handleControl(release, now: 1.3)
        #expect(latch.contains(.write(ChromecastPublicVoiceArbiter.micOpen)))
        #expect(!latch.contains { if case .stopRecognition = $0 { return true } else { return false } })
        #expect(arbiter.needsExtend)
        // 宿主流开始推送：不产生用户可见动作。
        #expect(!arbiter.handleControl(hostStream, now: 1.35).contains(.startRecognition))
        let second = arbiter.handleControl(press, now: 5)
        #expect(second.contains(.stopRecognition(.toggleSecondTap)))
        #expect(second.contains(.write(ChromecastPublicVoiceArbiter.micClose)))
        #expect(!arbiter.recognitionOpen)
        // 第二次按下的松键与 MIC_CLOSE 之后的 AUDIO_STOP 都不得再开会话或重复结束。
        let tail = arbiter.handleControl(release, now: 5.4) + arbiter.handleControl(release, now: 5.5)
        #expect(!tail.contains(.startRecognition))
        #expect(!tail.contains(.write(ChromecastPublicVoiceArbiter.micOpen)))
        #expect(!tail.contains { if case .stopRecognition = $0 { return true } else { return false } })
    }

    @Test func toggleModeDebouncesRapidSecondPress() {
        var arbiter = ChromecastPublicVoiceArbiter()
        arbiter.mode = .toggle
        _ = arbiter.handleControl(press, now: 0)
        _ = arbiter.handleControl(release, now: 1.3)
        // latch 后 1 ms 再按：防抖，不关闭。
        let rapid = arbiter.handleControl(press, now: 1.301)
        #expect(!rapid.contains { if case .stopRecognition = $0 { return true } else { return false } })
        #expect(arbiter.handleControl(release, now: 2.6).contains(.log("gesture=release action=none mode=toggle")))
        #expect(arbiter.recognitionOpen && arbiter.needsExtend)
        // 窗口外再按一次：正常关闭。
        #expect(arbiter.handleControl(press, now: 4).contains(.stopRecognition(.toggleSecondTap)))
    }

    @Test func remoteEndingHostStreamIsForcedStop() {
        var arbiter = ChromecastPublicVoiceArbiter()
        arbiter.mode = .toggle
        _ = arbiter.handleControl(press, now: 0)
        _ = arbiter.handleControl(release, now: 1)
        _ = arbiter.handleControl(hostStream, now: 1.05)
        let ended = arbiter.handleControl(release, now: 60)
        #expect(ended.contains(.stopRecognition(.cancelled("remote_stream_ended"))))
        #expect(!arbiter.recognitionOpen)
    }

    @Test func hostEndClosesOnlyHostOpenedStream() {
        var arbiter = ChromecastPublicVoiceArbiter()
        arbiter.mode = .toggle
        _ = arbiter.handleControl(press, now: 0)
        // 物理流进行中由宿主结束：远端会自己 AUDIO_STOP，不写 MIC_CLOSE。
        #expect(arbiter.hostEnded().isEmpty)
        _ = arbiter.handleControl(press, now: 2)
        _ = arbiter.handleControl(release, now: 3)
        #expect(arbiter.hostEnded() == [.write(ChromecastPublicVoiceArbiter.micClose)])
        #expect(!arbiter.recognitionOpen && !arbiter.needsExtend)
    }

    @Test func syncAndUnknownOpcodes() {
        var arbiter = ChromecastPublicVoiceArbiter()
        #expect(arbiter.handleControl(Data([0x0A, 0x02, 0x00, 0x10, 0xFF, 0x38, 0x1F]), now: 0)
            == [.resync(predictor: -200, stepIndex: 31)])
        #expect(arbiter.handleControl(Data([0x0A, 0x00, 0x01]), now: 0).isEmpty)
        #expect(arbiter.handleControl(Data([0x0B, 0x01, 0x00]), now: 0).isEmpty)
        #expect(arbiter.handleControl(Data([0x7F]), now: 0) == [.log("control=unknown opcode=0x7f bytes=1")])
    }

    @Test func capsResponseFromRealRemoteParses() {
        // 维护者 macOS 真机原文：0b0100020300f70100
        let caps = ATVVCapabilities.parse(Data([0x0B, 0x01, 0x00, 0x02, 0x03, 0x00, 0xF7, 0x01, 0x00]))
        #expect(caps?.version == 0x0100)
        #expect(caps?.sampleRate == 16_000)
        #expect(caps?.interaction == 0x03)
        #expect(caps?.frameSize == 247)
    }

    @Test func legacyProtocolRemoteIsHoldOnly() {
        // 用户真机：caps_response version=0x4 frame=134
        let legacy = ChromecastPublicRemoteDriver.declaredCapabilities(protocolVersion: 0x0004)
        #expect(legacy.contains(.voiceStream))
        #expect(!legacy.contains(.toggleVoiceGesture))
        let caps = ATVVCapabilities.parse(Data([0x0B, 0x00, 0x04, 0x00, 0x02, 0x00, 0x86, 0x00, 0x14]))
        #expect(caps?.version == 0x0004)
        #expect(caps?.frameSize == ChromecastPublicProtocol.legacyFrameLength)
    }

    @Test func declaresToggleCapableVoice() {
        let declared = ChromecastPublicRemoteDriver.declaredCapabilities
        #expect(declared.contains(.voiceStream))
        #expect(declared.contains(.controlEdges))
        #expect(declared.contains(.toggleVoiceGesture))
        #expect(!declared.contains(.battery))
        let capabilities = RemoteVoiceCapabilities.resolve(model: .chromecastVoiceRemote, declared: declared)
        #expect(capabilities.supportsToggleVoiceRecording)
    }

    // MARK: - 画布布局

    @Test func canvasPlacesEveryControlOnce() {
        let placed = ChromecastRemoteLayout.placements.map(\.controlID)
        #expect(Set(placed) == Set(ChromecastRemoteControl.allCases.map(\.rawValue)))
        #expect(placed.count == Set(placed).count)
        #expect(ChromecastRemoteLayout.rightColumn.contains(ChromecastRemoteLayout.voiceControlID))
        for control in ChromecastRemoteControl.allCases {
            let anchor = ChromecastRemoteLayout.anchors[control.rawValue]
            #expect(anchor != nil)
            if let anchor {
                #expect((0...1).contains(anchor.x) && (0...1).contains(anchor.y))
            }
        }
    }

    @Test func canvasCardsDoNotOverlap() {
        for column in [ChromecastRemoteLayout.leftColumn, ChromecastRemoteLayout.rightColumn] {
            let centers = column.map(ChromecastRemoteLayout.cardCenterY(for:))
            for (upper, lower) in zip(centers, centers.dropFirst()) {
                #expect(lower - upper >= ChromecastRemoteLayout.cardHeight)
            }
            #expect((centers.first ?? 0) - ChromecastRemoteLayout.cardHeight / 2 >= 0)
            #expect((centers.last ?? 0) + ChromecastRemoteLayout.cardHeight / 2 <= ChromecastRemoteLayout.canvasHeight + 0.5)
        }
    }
}
