import SwiftUI
import Combine

// MARK: - Design Tokens (matching littlerip.com)

extension Color {
    static let lrBg        = Color(red: 0.04, green: 0.03, blue: 0.02)
    static let lrPanel     = Color(red: 0.07, green: 0.055, blue: 0.04)
    static let lrBorder    = Color(red: 0.72, green: 0.60, blue: 0.42, opacity: 0.18)
    static let lrBorderLt  = Color(red: 0.72, green: 0.60, blue: 0.42, opacity: 0.10)
    static let lrMuted     = Color(red: 0.66, green: 0.60, blue: 0.50)
    static let lrText      = Color(red: 0.94, green: 0.91, blue: 0.85)
    static let lrAccent    = Color(red: 0.79, green: 0.66, blue: 0.30)
    static let lrAccentDim = Color(red: 0.79, green: 0.66, blue: 0.30, opacity: 0.15)
}

// MARK: - Key Monitor

class KeyMonitor: ObservableObject {
    @Published var pressedKeys: Set<UInt16> = []

    private var monitor: Any?
    private let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let isArrow = self?.arrowKeyCodes.contains(event.keyCode) ?? false
            if isArrow {
                if event.type == .keyDown {
                    self?.pressedKeys.insert(event.keyCode)
                } else {
                    self?.pressedKeys.remove(event.keyCode)
                }
                return nil
            }
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    var isUpPressed: Bool { pressedKeys.contains(126) }
    var isDownPressed: Bool { pressedKeys.contains(125) }
    var isLeftPressed: Bool { pressedKeys.contains(123) }
    var isRightPressed: Bool { pressedKeys.contains(124) }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var camera = CameraService()
    @StateObject private var model = VisionService()
    @StateObject private var keys = KeyMonitor()

    var body: some View {
        ZStack {
            Color.lrBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Title ──
                Text("LittleRip")
                    .font(.custom("Playfair Display", size: 38))
                    .tracking(6)
                    .foregroundStyle(Color(red: 1, green: 0.98, blue: 0.94))
                    .padding(.top, 28)

                Spacer()

                // ── D-Pad Controller ──
                DPadController(keys: keys, activeDirection: model.currentDirection)
                    .padding(.horizontal, 28)

                Spacer().frame(height: 12)

                // ── Frame Preview ──
                ZStack {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.black.opacity(0.75))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.lrBorder, lineWidth: 1)
                        )

                    if let image = camera.latestFrame {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .padding(4)
                            .id(image)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.lrMuted.opacity(0.3))
                            Text("no frame")
                                .font(.custom("EB Garamond", size: 13))
                                .tracking(2)
                                .foregroundStyle(Color.lrMuted.opacity(0.35))
                        }
                    }
                }
                .aspectRatio(4/3, contentMode: .fit)
                .frame(maxWidth: 340)
                .padding(.horizontal, 28)

                Spacer()

                // ── Pipeline Cards ──
                VStack(spacing: 10) {
                    PipelineCard(
                        icon: "camera.fill",
                        label: "Camera",
                        detail: camera.isOn ? "FFmpeg 1 FPS → /tmp/littlerip_latest.jpg" : "Off",
                        isOn: camera.isOn,
                        isStarting: camera.isStarting,
                        color: Color.lrAccent
                    ) {
                        if camera.isOn { camera.stop() } else { camera.start() }
                    }

                    PipelineCard(
                        icon: "brain",
                        label: "Vision",
                        detail: model.isOn ? "\(model.framesAnalyzed) frames · \(model.lastLatencyMs)ms" : "Off",
                        isOn: model.isOn,
                        isStarting: model.isAnalyzing,
                        color: Color.lrAccent
                    ) {
                        if model.isOn { model.stop() } else { model.start() }
                    }
                    .opacity(camera.isOn ? 1.0 : 0.35)
                    .disabled(!camera.isOn)
                }
                .frame(maxWidth: 340)
                .padding(.bottom, 24)
            }
        }
        .frame(minWidth: 380, minHeight: 500)
    }
}

// MARK: - Squircle (Apple key shape)

struct Squircle: Shape {
    var cornerRadius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: w - r, y: 0))
        path.addCurve(to: CGPoint(x: w, y: r), control1: CGPoint(x: w - r * 0.55, y: 0), control2: CGPoint(x: w, y: r * 0.55))
        path.addLine(to: CGPoint(x: w, y: h - r))
        path.addCurve(to: CGPoint(x: w - r, y: h), control1: CGPoint(x: w, y: h - r * 0.55), control2: CGPoint(x: w - r * 0.55, y: h))
        path.addLine(to: CGPoint(x: r, y: h))
        path.addCurve(to: CGPoint(x: 0, y: h - r), control1: CGPoint(x: r * 0.55, y: h), control2: CGPoint(x: 0, y: h - r * 0.55))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addCurve(to: CGPoint(x: r, y: 0), control1: CGPoint(x: 0, y: r * 0.55), control2: CGPoint(x: r * 0.55, y: 0))
        return path
    }
}

// MARK: - D-Pad Controller

struct DPadController: View {
    @ObservedObject var keys: KeyMonitor
    var activeDirection: String?

    private let dirToKeyCode: [String: UInt16] = [
        "forward": 126, "up": 126,
        "back": 125, "backward": 125, "down": 125,
        "left": 123,
        "right": 124
    ]

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, 220)
            let keyW = size * 0.26
            let keyH = size * 0.22
            let gap = size * 0.03

            let activeCode = activeDirection.flatMap { dirToKeyCode[$0] }

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Spacer()
                    KeyCap(icon: "arrow.up", isPressed: keys.isUpPressed || activeCode == 126, width: keyW, height: keyH)
                    Spacer()
                }
                HStack(spacing: gap) {
                    KeyCap(icon: "arrow.left", isPressed: keys.isLeftPressed || activeCode == 123, width: keyW, height: keyH)
                    KeyCap(icon: "arrow.down", isPressed: keys.isDownPressed || activeCode == 125, width: keyW, height: keyH)
                    KeyCap(icon: "arrow.right", isPressed: keys.isRightPressed || activeCode == 124, width: keyW, height: keyH)
                }
                HStack(spacing: gap) {
                    Spacer()
                }
            }
            .frame(width: size, height: size * 0.7)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 180)
    }
}

// MARK: - Key Cap (Apple keyboard style)

struct KeyCap: View {
    let icon: String
    let isPressed: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            Squircle(cornerRadius: 6)
                .fill(Color.black.opacity(0.5))
                .offset(y: isPressed ? 0 : 2)
            Squircle(cornerRadius: 6)
                .fill(isPressed ? Color.lrAccent.opacity(0.3) : Color(red: 0.14, green: 0.12, blue: 0.10))
                .overlay(
                    Squircle(cornerRadius: 6)
                        .stroke(isPressed ? Color.lrAccent : Color.white.opacity(0.08), lineWidth: isPressed ? 1.5 : 0.5)
                )
                .offset(y: isPressed ? 1 : 0)
            Image(systemName: icon)
                .font(.system(size: min(width, height) * 0.32, weight: .medium))
                .foregroundStyle(isPressed ? Color.lrAccent : Color.lrMuted)
        }
        .frame(width: width, height: height)
        .animation(.easeInOut(duration: 0.08), value: isPressed)
    }
}

// MARK: - Pipeline Card

struct PipelineCard: View {
    let icon: String
    let label: String
    let detail: String
    let isOn: Bool
    let isStarting: Bool
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isOn ? color.opacity(0.12) : Color.white.opacity(0.04))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? color : Color.lrMuted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.custom("Playfair Display", size: 14))
                    .tracking(1)
                    .foregroundStyle(Color.lrText)
                Text(detail)
                    .font(.custom("EB Garamond", size: 11))
                    .foregroundStyle(Color.lrMuted)
                    .lineLimit(1)
            }
            Spacer()
            if isStarting && !isOn {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.lrAccent)
            } else {
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { _ in action() }
                ))
                .toggleStyle(.switch)
                .tint(Color.lrAccent)
                .labelsHidden()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isOn ? color.opacity(0.06) : (isHovered ? Color.white.opacity(0.03) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isOn ? color.opacity(0.25) : Color.lrBorder, lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}