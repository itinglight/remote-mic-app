import SwiftUI

// 公开构建的 Chromecast 语音遥控器插画与按键画布。
//
// 私有包 `SayAllChromecast` 自带真机图与画布；未编入私有包时由本文件提供同名接口的替代实现。
// 插画用 SwiftUI 矢量绘制，只表达按键的相对位置，不使用任何厂商照片或商标图形。

/// 插画上每个按键的归一化位置（相对遥控器正面尺寸）。
enum ChromecastRemoteLayout {
    static let remoteSize = CGSize(width: 150, height: 500)
    /// 遥控器机身宽度占插画宽度的比例；右侧留出音量键的凸起。
    static let bodyWidthRatio: CGFloat = 0.9

    struct Placement: Identifiable {
        let controlID: String
        let side: RemoteMappingSide
        /// 插画内的锚点（0…1）。
        let anchor: UnitPoint
        var id: String { controlID }
    }

    static let voiceControlID = "voice"
    static let voiceAnchor = UnitPoint(x: 0.68, y: 0.37)

    static let anchors: [String: UnitPoint] = [
        "up": UnitPoint(x: 0.45, y: 0.115),
        "left": UnitPoint(x: 0.17, y: 0.20),
        "select": UnitPoint(x: 0.45, y: 0.20),
        "right": UnitPoint(x: 0.73, y: 0.20),
        "down": UnitPoint(x: 0.45, y: 0.285),
        "back": UnitPoint(x: 0.22, y: 0.37),
        "home": UnitPoint(x: 0.22, y: 0.47),
        "mute": UnitPoint(x: 0.68, y: 0.47),
        "youtube": UnitPoint(x: 0.22, y: 0.57),
        "netflix": UnitPoint(x: 0.68, y: 0.57),
        "volume_up": UnitPoint(x: 0.96, y: 0.42),
        "volume_down": UnitPoint(x: 0.96, y: 0.52),
        "power": UnitPoint(x: 0.30, y: 0.88),
        "input": UnitPoint(x: 0.60, y: 0.88),
    ]

    /// 卡片顺序按锚点从上到下排，连线尽量不交叉。语音键固定在右列。
    static let leftColumn = ["up", "left", "down", "back", "home", "youtube", "power"]
    static let rightColumn = ["right", "select", voiceControlID, "volume_up", "mute", "volume_down", "netflix", "input"]

    static var placements: [Placement] {
        leftColumn.map { Placement(controlID: $0, side: .left, anchor: anchors[$0] ?? .center) }
            + rightColumn.filter { $0 != voiceControlID }
            .map { Placement(controlID: $0, side: .right, anchor: anchors[$0] ?? .center) }
    }

    /// 卡片图标。YouTube、Netflix、信源在通用按键表里没有专属图标，这里给中性的 SF Symbol。
    static func systemImage(for controlID: String) -> String {
        switch controlID {
        case "youtube": return "play.rectangle"
        case "netflix": return "film"
        case "input": return "rectangle.on.rectangle"
        default:
            return ChromecastRemoteControl(rawValue: controlID)?.remoteButton.systemImage ?? "circle"
        }
    }

    static let cardHeight: CGFloat = 72
    static let cardSpacing: CGFloat = 8
    static var canvasHeight: CGFloat {
        let rows = CGFloat(max(leftColumn.count, rightColumn.count))
        return rows * cardHeight + (rows - 1) * cardSpacing
    }

    /// 卡片中心在画布中的纵坐标。
    static func cardCenterY(for controlID: String) -> CGFloat {
        let column = leftColumn.contains(controlID) ? leftColumn : rightColumn
        guard let index = column.firstIndex(of: controlID) else { return canvasHeight / 2 }
        // 较短的一列整体居中，避免底部留空。
        let used = CGFloat(column.count) * cardHeight + CGFloat(column.count - 1) * cardSpacing
        let top = (canvasHeight - used) / 2
        return top + CGFloat(index) * (cardHeight + cardSpacing) + cardHeight / 2
    }
}

// MARK: - 插画

/// 矢量绘制的 Chromecast 语音遥控器（正面 + 右侧音量键）。
struct ChromecastRemoteIllustration: View {
    var activeControlIDs: Set<String> = []
    var selectedControlID: String?
    var voiceActive = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let bodyWidth = size.width * ChromecastRemoteLayout.bodyWidthRatio
            ZStack(alignment: .topLeading) {
                volumeRocker(size: size, bodyWidth: bodyWidth)
                remoteBody(width: bodyWidth, height: size.height)
                indicatorLight(size: size)
                directionPad(size: size)
                roundButton("back", symbol: "arrow.uturn.backward", size: size)
                assistantButton(size: size)
                roundButton("home", symbol: "house", size: size)
                roundButton("mute", symbol: "speaker.slash", size: size)
                textButton("youtube", title: "YouTube", size: size)
                textButton("netflix", title: "Netflix", size: size)
                smallButton("power", symbol: "power", size: size)
                smallButton("input", symbol: "rectangle.on.rectangle", size: size)
            }
        }
        .aspectRatio(
            ChromecastRemoteLayout.remoteSize.width / ChromecastRemoteLayout.remoteSize.height,
            contentMode: .fit
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("remote.device.model.chromecast_voice_remote"))
    }

    // MARK: 配色

    private var shellFill: LinearGradient {
        let top = colorScheme == .dark ? Color(white: 0.86) : Color(white: 0.985)
        let bottom = colorScheme == .dark ? Color(white: 0.76) : Color(white: 0.92)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    private var shellStroke: Color { Color.black.opacity(colorScheme == .dark ? 0.35 : 0.14) }
    private var keyFill: Color { Color(white: colorScheme == .dark ? 0.80 : 0.95) }
    private var keyStroke: Color { Color.black.opacity(0.16) }
    private var glyph: Color { Color(white: 0.28) }

    private func keyTint(_ controlID: String) -> Color? {
        if activeControlIDs.contains(controlID) { return .orange }
        if selectedControlID == controlID { return .accentColor }
        return nil
    }

    // MARK: 机身

    private func remoteBody(width: CGFloat, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.46, style: .circular)
        return shape
            .fill(shellFill)
            .overlay(shape.stroke(shellStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
            .frame(width: width, height: height)
    }

    private func volumeRocker(size: CGSize, bodyWidth: CGFloat) -> some View {
        let top = size.height * 0.385
        let height = size.height * 0.17
        let tintUp = keyTint("volume_up")
        let tintDown = keyTint("volume_down")
        return ZStack {
            Capsule()
                .fill(keyFill)
                .overlay(Capsule().stroke(keyStroke, lineWidth: 1))
            VStack(spacing: 0) {
                (tintUp ?? .clear).opacity(0.55)
                (tintDown ?? .clear).opacity(0.55)
            }
            .clipShape(Capsule())
        }
        .frame(width: size.width - bodyWidth + 10, height: height)
        .offset(x: bodyWidth - 10, y: top)
    }

    private func indicatorLight(size: CGSize) -> some View {
        let tint: Color = voiceActive ? .orange : Color(white: 0.55)
        return Circle()
            .fill(tint)
            .frame(width: 4, height: 4)
            .position(x: size.width * 0.45, y: size.height * 0.045)
    }

    // MARK: 方向键

    private func directionPad(size: CGSize) -> some View {
        let center = point(UnitPoint(x: 0.45, y: 0.20), in: size)
        let diameter = size.width * 0.78
        let selectDiameter = diameter * 0.44
        return ZStack {
            Circle()
                .fill(keyFill)
                .overlay(Circle().stroke(keyStroke, lineWidth: 1))
            ForEach(["up", "down", "left", "right"], id: \.self) { controlID in
                padSegmentHighlight(controlID, diameter: diameter)
            }
            ForEach(["up", "down", "left", "right"], id: \.self) { controlID in
                Circle()
                    .fill(glyph.opacity(0.55))
                    .frame(width: 3.5, height: 3.5)
                    .offset(padDotOffset(controlID, radius: diameter * 0.36))
            }
            Circle()
                .fill(shellFill)
                .overlay(Circle().stroke(keyTint("select") ?? keyStroke, lineWidth: keyTint("select") == nil ? 1 : 2.5))
                .frame(width: selectDiameter, height: selectDiameter)
        }
        .frame(width: diameter, height: diameter)
        .position(center)
    }

    @ViewBuilder
    private func padSegmentHighlight(_ controlID: String, diameter: CGFloat) -> some View {
        if let tint = keyTint(controlID) {
            let startAngle: Double = switch controlID {
            case "up": 225
            case "right": 315
            case "down": 45
            default: 135
            }
            PadSegment(startDegrees: startAngle, sweepDegrees: 90, innerRatio: 0.48)
                .fill(tint.opacity(0.5))
                .frame(width: diameter, height: diameter)
        }
    }

    private func padDotOffset(_ controlID: String, radius: CGFloat) -> CGSize {
        switch controlID {
        case "up": CGSize(width: 0, height: -radius)
        case "down": CGSize(width: 0, height: radius)
        case "left": CGSize(width: -radius, height: 0)
        default: CGSize(width: radius, height: 0)
        }
    }

    // MARK: 普通按键

    private func roundButton(_ controlID: String, symbol: String, size: CGSize) -> some View {
        let diameter = size.width * 0.27
        return keyCircle(controlID, diameter: diameter) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.40, weight: .semibold))
                .foregroundStyle(glyph)
        }
        .position(point(ChromecastRemoteLayout.anchors[controlID] ?? .center, in: size))
    }

    private func assistantButton(size: CGSize) -> some View {
        let diameter = size.width * 0.27
        let tint: Color? = voiceActive ? .orange : (selectedControlID == ChromecastRemoteLayout.voiceControlID ? .accentColor : nil)
        return ZStack {
            Circle()
                .fill(keyFill)
                .overlay(Circle().stroke(tint ?? keyStroke, lineWidth: tint == nil ? 1 : 2.5))
            // 中性的四点语音标识，不复刻任何厂商图标。
            let dot = diameter * 0.13
            HStack(spacing: dot * 0.45) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(glyph.opacity(index.isMultiple(of: 2) ? 0.85 : 0.55))
                        .frame(width: dot, height: dot)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .position(point(ChromecastRemoteLayout.voiceAnchor, in: size))
    }

    private func textButton(_ controlID: String, title: String, size: CGSize) -> some View {
        let diameter = size.width * 0.27
        return keyCircle(controlID, diameter: diameter) {
            Text(verbatim: title)
                .font(.system(size: diameter * 0.17, weight: .bold))
                .foregroundStyle(glyph)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 2)
        }
        .position(point(ChromecastRemoteLayout.anchors[controlID] ?? .center, in: size))
    }

    private func smallButton(_ controlID: String, symbol: String, size: CGSize) -> some View {
        let diameter = size.width * 0.17
        return keyCircle(controlID, diameter: diameter) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.42, weight: .semibold))
                .foregroundStyle(glyph)
        }
        .position(point(ChromecastRemoteLayout.anchors[controlID] ?? .center, in: size))
    }

    private func keyCircle<Content: View>(
        _ controlID: String,
        diameter: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let tint = keyTint(controlID)
        return ZStack {
            Circle()
                .fill(tint.map { $0.opacity(0.28) } ?? keyFill)
                .overlay(Circle().stroke(tint ?? keyStroke, lineWidth: tint == nil ? 1 : 2.5))
            content()
        }
        .frame(width: diameter, height: diameter)
    }

    private func point(_ anchor: UnitPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * anchor.x, y: size.height * anchor.y)
    }
}

/// 方向键的一段扇环，用于按下/选中高亮。
private struct PadSegment: Shape {
    let startDegrees: Double
    let sweepDegrees: Double
    let innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var path = Path()
        path.addArc(
            center: center, radius: outer,
            startAngle: .degrees(startDegrees), endAngle: .degrees(startDegrees + sweepDegrees),
            clockwise: false
        )
        path.addArc(
            center: center, radius: inner,
            startAngle: .degrees(startDegrees + sweepDegrees), endAngle: .degrees(startDegrees),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

/// 连接页、Onboarding 使用的遥控器小图。接口与私有包的 `ChromecastConnectionPhoto` 一致。
struct ChromecastPublicConnectionPhoto: View {
    var body: some View {
        ChromecastRemoteIllustration()
            .frame(width: 52, height: 166)
            .padding(.vertical, 2)
    }
}

// MARK: - 按键画布

/// Chromecast 按键页画布。参数与私有包 `ChromecastMappingCanvas` 一致，宿主按键页无需分支。
struct ChromecastPublicMappingCanvas: View {
    struct Labels {
        let voiceTitle: String
        let voiceFixed: String
        let voiceDetail: String
        let missingPhoto: String
    }

    @Binding var selectedControlID: String
    let activeControlIDs: Set<String>
    let voiceActive: Bool
    let labels: Labels
    let buttonTitle: (String) -> String
    let triggerTitle: (String) -> String
    let actionSummary: (String, String) -> String
    let holdSummary: (String) -> String
    let onEdit: (String, String) -> Void
    let onEditHold: (String) -> Void
    var systemReservedControlIDs: Set<String> = []
    var onVoiceSettings: () -> Void = {}

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let cardWidth = RemoteMappingLayout.cardWidth(for: width)
            ZStack {
                ChromecastRemoteIllustration(
                    activeControlIDs: activeControlIDs,
                    selectedControlID: selectedControlID,
                    voiceActive: voiceActive
                )
                .frame(
                    width: ChromecastRemoteLayout.remoteSize.width,
                    height: ChromecastRemoteLayout.remoteSize.height
                )
                .position(x: width / 2, y: ChromecastRemoteLayout.canvasHeight / 2)

                connectionLines(width: width, cardWidth: cardWidth)

                ForEach(ChromecastRemoteLayout.placements) { placement in
                    mappingCard(placement.controlID)
                        .frame(width: cardWidth, height: ChromecastRemoteLayout.cardHeight)
                        .position(
                            x: placement.side == .left ? cardWidth / 2 : width - cardWidth / 2,
                            y: ChromecastRemoteLayout.cardCenterY(for: placement.controlID)
                        )
                }

                voiceCard
                    .frame(width: cardWidth, height: ChromecastRemoteLayout.cardHeight)
                    .position(
                        x: width - cardWidth / 2,
                        y: ChromecastRemoteLayout.cardCenterY(for: ChromecastRemoteLayout.voiceControlID)
                    )
            }
        }
        .frame(height: ChromecastRemoteLayout.canvasHeight)
    }

    // MARK: 连线

    private func remotePoint(_ anchor: UnitPoint, width: CGFloat) -> CGPoint {
        let size = ChromecastRemoteLayout.remoteSize
        let origin = CGPoint(
            x: width / 2 - size.width / 2,
            y: (ChromecastRemoteLayout.canvasHeight - size.height) / 2
        )
        return CGPoint(x: origin.x + size.width * anchor.x, y: origin.y + size.height * anchor.y)
    }

    private func connectionLines(width: CGFloat, cardWidth: CGFloat) -> some View {
        Canvas { context, _ in
            for placement in ChromecastRemoteLayout.placements {
                draw(
                    context: &context,
                    start: remotePoint(placement.anchor, width: width),
                    end: CGPoint(
                        x: placement.side == .left ? cardWidth : width - cardWidth,
                        y: ChromecastRemoteLayout.cardCenterY(for: placement.controlID)
                    ),
                    side: placement.side,
                    selected: selectedControlID == placement.controlID,
                    showsAnchor: activeControlIDs.contains(placement.controlID)
                )
            }
            draw(
                context: &context,
                start: remotePoint(ChromecastRemoteLayout.voiceAnchor, width: width),
                end: CGPoint(
                    x: width - cardWidth,
                    y: ChromecastRemoteLayout.cardCenterY(for: ChromecastRemoteLayout.voiceControlID)
                ),
                side: .right,
                selected: voiceActive,
                showsAnchor: voiceActive
            )
        }
        .allowsHitTesting(false)
    }

    private func draw(
        context: inout GraphicsContext,
        start: CGPoint,
        end: CGPoint,
        side: RemoteMappingSide,
        selected: Bool,
        showsAnchor: Bool
    ) {
        let tip = RemoteMappingLayout.arrowTip(cardEdge: end, side: side)
        let controls = RemoteMappingLayout.connectionControlPoints(start: start, end: tip, side: side)
        var path = Path()
        path.move(to: start)
        path.addCurve(to: tip, control1: controls.start, control2: controls.end)
        let color = selected ? Color.accentColor : Color.secondary.opacity(0.42)
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: selected ? 1.6 : 1.0, lineCap: .round, lineJoin: .round)
        )
        context.fill(
            Path(ellipseIn: CGRect(x: start.x - 2.5, y: start.y - 2.5, width: 5, height: 5)),
            with: .color(showsAnchor ? Color.orange : color)
        )
        let direction: CGFloat = side == .left ? -1 : 1
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x - direction * 6, y: tip.y - 4))
        arrow.addLine(to: CGPoint(x: tip.x - direction * 6, y: tip.y + 4))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    // MARK: 卡片

    private func mappingCard(_ controlID: String) -> some View {
        let selected = selectedControlID == controlID
        let active = activeControlIDs.contains(controlID)
        let reserved = systemReservedControlIDs.contains(controlID)
        let title = buttonTitle(controlID)
        let systemImage = ChromecastRemoteLayout.systemImage(for: controlID)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    selectedControlID = controlID
                    onEditHold(controlID)
                } label: {
                    Text(holdSummary(controlID))
                        .font(.system(
                            size: RemoteMappingCardChrome.HoldChip.fontSize,
                            weight: RemoteMappingCardChrome.HoldChip.fontWeight
                        ))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, RemoteMappingCardChrome.HoldChip.horizontalPadding)
                        .padding(.vertical, RemoteMappingCardChrome.HoldChip.verticalPadding)
                        .background(
                            RemoteMappingCardChrome.HoldChip.background,
                            in: RoundedRectangle(cornerRadius: RemoteMappingCardChrome.HoldChip.cornerRadius)
                        )
                }
                .buttonStyle(.plain)
                .help("\(title) · \(holdSummary(controlID))")
            }

            HStack(spacing: 4) {
                ForEach(ButtonTrigger.allCases) { trigger in
                    Button {
                        selectedControlID = controlID
                        onEdit(controlID, trigger.rawValue)
                    } label: {
                        VStack(spacing: 1) {
                            Text(triggerTitle(trigger.rawValue))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(actionSummary(controlID, trigger.rawValue))
                                .font(.system(size: 12, weight: trigger == .singleClick ? .semibold : .regular))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("\(title) · \(triggerTitle(trigger.rawValue)) — \(actionSummary(controlID, trigger.rawValue))")
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { selectedControlID = controlID }
        .background(
            active
                ? Color.orange.opacity(0.12)
                : selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    active
                        ? Color.orange.opacity(0.65)
                        : selected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.15)
                )
        }
        .opacity(reserved ? 0.5 : 1)
        .allowsHitTesting(!reserved)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private var voiceCard: some View {
        Button(action: onVoiceSettings) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .frame(width: 14)
                    Text(labels.voiceTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(labels.voiceFixed)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(voiceActive ? Color.orange : Color.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((voiceActive ? Color.orange : Color.secondary).opacity(0.12), in: Capsule())
                }
                Text(labels.voiceDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                voiceActive ? Color.orange.opacity(0.12) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(voiceActive ? Color.orange.opacity(0.65) : Color.secondary.opacity(0.15))
            }
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }
}

#if !canImport(SayAllChromecast)
/// 未编入私有包时，宿主沿用私有包的类型名，按键页与连接页无需各写一套分支。
typealias ChromecastMappingCanvas = ChromecastPublicMappingCanvas
typealias ChromecastConnectionPhoto = ChromecastPublicConnectionPhoto
#endif
