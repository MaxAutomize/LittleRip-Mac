import SwiftUI
import Combine

// MARK: - Chrome / Retro Space Console Theme

extension Color {
    static let botBlack = Color(red: 0.015, green: 0.017, blue: 0.020)
    static let botPanel = Color(red: 0.045, green: 0.050, blue: 0.055)
    static let botPanel2 = Color(red: 0.075, green: 0.082, blue: 0.088)
    static let botChrome = Color(red: 0.78, green: 0.81, blue: 0.82)
    static let botChromeDark = Color(red: 0.33, green: 0.36, blue: 0.37)
    static let botWhite = Color(red: 0.94, green: 0.96, blue: 0.96)
    static let botGreen = Color(red: 0.58, green: 1.0, blue: 0.26)
    static let botRed = Color(red: 1.0, green: 0.22, blue: 0.22)
    static let botAmber = Color(red: 1.0, green: 0.78, blue: 0.28)
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

    var isLeftPressed: Bool { pressedKeys.contains(123) }
    var isRightPressed: Bool { pressedKeys.contains(124) }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var camera = CameraService()
    @StateObject private var frameAI = VisionService()
    @StateObject private var sensor = UltrasonicSensorService()
    @StateObject private var keys = KeyMonitor()

    private var primaryCamera: CameraConfig? { camera.cameras.first }

    var body: some View {
        ZStack {
            RetroBackground()

            GeometryReader { proxy in
                let dashboardWidth: CGFloat = 1060
                let dashboardHeight: CGFloat = 760
                let scale = min(proxy.size.width / dashboardWidth, proxy.size.height / dashboardHeight, 1)

                DashboardCanvas(
                    camera: camera,
                    frameAI: frameAI,
                    sensor: sensor,
                    keys: keys,
                    cameraToggle: toggleCamera,
                    sensorToggle: toggleSensor,
                    aiToggle: toggleFrameAI
                )
                .frame(width: dashboardWidth, height: dashboardHeight, alignment: .topLeading)
                .scaleEffect(scale, anchor: .center)
                .frame(width: dashboardWidth * scale, height: dashboardHeight * scale)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .frame(minWidth: 120, minHeight: 90)
        .onDisappear {
            frameAI.stop()
            camera.stop()
            sensor.stop()
        }
    }

    private func toggleCamera() {
        guard let config = primaryCamera else { return }
        if camera.isOn || camera.isStarting {
            camera.stop(camera: config)
            frameAI.stop()
        } else {
            camera.setFrameMode(.fast)
            frameAI.setFrameMode(.fast)
            camera.start(camera: config)
        }
    }

    private func toggleSensor() {
        sensor.isOn ? sensor.stop() : sensor.start()
    }

    private func toggleFrameAI() {
        if frameAI.isOn {
            frameAI.stop()
        } else if camera.isOn {
            frameAI.start(frameMode: .fast, camera: camera)
        }
    }
}

// MARK: - Dashboard Canvas

struct DashboardCanvas: View {
    @ObservedObject var camera: CameraService
    @ObservedObject var frameAI: VisionService
    @ObservedObject var sensor: UltrasonicSensorService
    @ObservedObject var keys: KeyMonitor

    let cameraToggle: () -> Void
    let sensorToggle: () -> Void
    let aiToggle: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HeaderDeck()

            HStack(alignment: .top, spacing: 12) {
                CameraFramePanel(
                    title: "CAMERA FRAME",
                    image: camera.latestFrame,
                    isOn: camera.isOn,
                    isStarting: camera.isStarting,
                    frameCount: frameAI.framesAnalyzed,
                    latency: frameAI.lastLatencyMs,
                    directive: frameAI.currentDirection
                )

                SensorPanel(sensor: sensor)
            }

            LaunchSwitchBoard(
                cameraOn: camera.isOn || camera.isStarting,
                cameraStarting: camera.isStarting,
                sensorOn: sensor.isOn,
                aiOn: frameAI.isOn,
                aiThinking: frameAI.isAnalyzing,
                cameraToggle: cameraToggle,
                sensorToggle: sensorToggle,
                aiToggle: aiToggle
            )

            FootControls(
                leftActive: keys.isLeftPressed || frameAI.currentDirection == "left",
                rightActive: keys.isRightPressed || frameAI.currentDirection == "right",
                leftAction: { Task { await KeySimulator.press(direction: "left", duration: 0.25) } },
                rightAction: { Task { await KeySimulator.press(direction: "right", duration: 0.25) } }
            )
        }
        .padding(14)
        .frame(width: 1060, height: 760, alignment: .topLeading)
    }
}

// MARK: - Header

struct HeaderDeck: View {
    var body: some View {
        HStack(spacing: 18) {
            Image("LittleBotIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 78)
                .shadow(color: .white.opacity(0.22), radius: 16)

            VStack(alignment: .leading, spacing: 6) {
                Text("LittleRip")
                    .font(.system(size: 36, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.botWhite)
                    .shadow(color: Color.botChrome.opacity(0.55), radius: 6)

                Text("ROBOT CONTROL CENTER")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(Color.botGreen)

                Text("camera frames • ultrasonic range • left foot / right foot")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Color.botChrome.opacity(0.72))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                StatusLight(label: "SYSTEM", color: Color.botGreen, isOn: true)
                StatusLight(label: "RETRO BUS", color: Color.botAmber, isOn: true)
                StatusLight(label: "BOT LINK", color: Color.botGreen, isOn: true)
            }
        }
        .padding(14)
        .background(ConsolePanelShape().fill(Color.botPanel.opacity(0.90)))
        .overlay(ConsolePanelShape().stroke(Color.botChrome.opacity(0.38), lineWidth: 2))
    }
}

// MARK: - Panels

struct CameraFramePanel: View {
    let title: String
    let image: NSImage?
    let isOn: Bool
    let isStarting: Bool
    let frameCount: Int
    let latency: Int
    let directive: String?

    var body: some View {
        ConsolePanel(title: title, subtitle: isOn ? "LIVE FFmpeg frame feed" : (isStarting ? "CONNECTING" : "STANDBY")) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.82))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.botChrome.opacity(0.45), lineWidth: 2))

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(8)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "video.slash.fill")
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(Color.botChromeDark)
                        Text("NO CAMERA FRAME")
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(Color.botChrome.opacity(0.65))
                        Text("toggle CAMERA to pull /tmp/littlerip_latest.jpg")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.botChromeDark)
                    }
                }

                VStack {
                    HStack {
                        MetricBadge(label: "FRAMES", value: "\(frameCount)")
                        MetricBadge(label: "LATENCY", value: latency > 0 ? "\(latency)ms" : "—")
                        Spacer()
                        MetricBadge(label: "MOVE", value: directive?.uppercased() ?? "IDLE", glow: directive != nil)
                    }
                    Spacer()
                }
                .padding(12)
            }
            .aspectRatio(16/10, contentMode: .fit)
            .frame(height: 292)
        }
    }
}

struct SensorPanel: View {
    @ObservedObject var sensor: UltrasonicSensorService

    var body: some View {
        ConsolePanel(title: "HC-SR04 ULTRASONIC", subtitle: sensor.isOn ? "RANGE SENSOR ONLINE" : "RANGE SENSOR OFF") {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color.botChrome.opacity(0.25), lineWidth: 12)
                        .frame(width: 138, height: 138)
                    Circle()
                        .trim(from: 0, to: trimValue)
                        .stroke(sensor.distanceCM == nil ? Color.botChromeDark : Color.botGreen, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 138, height: 138)
                        .shadow(color: Color.botGreen.opacity(sensor.distanceCM == nil ? 0 : 0.45), radius: 10)

                    VStack(spacing: 4) {
                        Text(sensor.statusText)
                            .font(.system(size: 24, weight: .black, design: .monospaced))
                            .minimumScaleFactor(0.45)
                            .lineLimit(1)
                            .foregroundStyle(sensor.distanceCM == nil ? Color.botChrome : Color.botGreen)
                        Text("ULTRA RANGE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(Color.botChrome.opacity(0.7))
                    }
                    .padding(.horizontal, 20)
                }

                VStack(alignment: .leading, spacing: 8) {
                    DataRow(label: "DATA PIPE", value: "/tmp/littlebot_hcsr04.txt")
                    DataRow(label: "RAW", value: sensor.lastRawValue)
                    DataRow(label: "UPDATED", value: sensor.lastUpdated.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
                }
            }
            .frame(maxWidth: 280)
        }
        .frame(width: 285)
    }

    private var trimValue: CGFloat {
        guard let distance = sensor.distanceCM else { return 0.08 }
        return min(max(CGFloat(distance / 200.0), 0.05), 1.0)
    }
}

// MARK: - Switchboard + Feet

struct LaunchSwitchBoard: View {
    let cameraOn: Bool
    let cameraStarting: Bool
    let sensorOn: Bool
    let aiOn: Bool
    let aiThinking: Bool
    let cameraToggle: () -> Void
    let sensorToggle: () -> Void
    let aiToggle: () -> Void

    var body: some View {
        ConsolePanel(title: "LAUNCH SWITCHBOARD", subtitle: "flip switches before engaging robot feet") {
            HStack(spacing: 14) {
                LaunchToggle(title: "CAMERA", subtitle: cameraStarting ? "CONNECTING" : "FRAME FEED", icon: "camera.fill", isOn: cameraOn, action: cameraToggle)
                LaunchToggle(title: "SENSOR", subtitle: "HC-SR04", icon: "dot.radiowaves.left.and.right", isOn: sensorOn, action: sensorToggle)
                LaunchToggle(title: "FRAME AI", subtitle: aiThinking ? "SCANNING" : "CAMERA → MOVE", icon: "brain.head.profile", isOn: aiOn, action: aiToggle)
            }
        }
    }
}

struct FootControls: View {
    let leftActive: Bool
    let rightActive: Bool
    let leftAction: () -> Void
    let rightAction: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            FootButton(title: "LEFT FOOT", key: "←", isActive: leftActive, action: leftAction)
            FootButton(title: "RIGHT FOOT", key: "→", isActive: rightActive, action: rightAction)
        }
    }
}

struct FootButton: View {
    let title: String
    let key: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(key)
                    .font(.system(size: 34, weight: .heavy, design: .monospaced))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .tracking(2)
                    Text("keyboard arrow output")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.5)
                        .opacity(0.65)
                }
                Spacer()
            }
            .foregroundStyle(isActive ? Color.black : Color.botWhite)
            .padding(.horizontal, 22)
            .frame(height: 74)
            .background(isActive ? Color.botGreen : Color.botPanel2)
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(isActive ? Color.botGreen : Color.botChrome.opacity(0.45), lineWidth: 3))
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .shadow(color: isActive ? Color.botGreen.opacity(0.55) : Color.clear, radius: 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Components

struct ConsolePanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .tracking(2.2)
                        .foregroundStyle(Color.botWhite)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.botChrome.opacity(0.62))
                }
                Spacer()
                StatusLight(label: "", color: Color.botGreen, isOn: subtitle.uppercased().contains("ON") || subtitle.uppercased().contains("LIVE") || subtitle.uppercased().contains("ONLINE"))
            }
            content
        }
        .padding(16)
        .background(ConsolePanelShape().fill(Color.botPanel.opacity(0.94)))
        .overlay(ConsolePanelShape().stroke(Color.botChrome.opacity(0.36), lineWidth: 2))
        .shadow(color: Color.black.opacity(0.55), radius: 20, y: 12)
    }
}

struct LaunchToggle: View {
    let title: String
    let subtitle: String
    let icon: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .heavy))
                    Spacer()
                    Capsule()
                        .fill(isOn ? Color.botGreen : Color.botChromeDark)
                        .frame(width: 46, height: 18)
                        .overlay(alignment: isOn ? .trailing : .leading) {
                            Circle()
                                .fill(isOn ? Color.black : Color.botWhite)
                                .frame(width: 14, height: 14)
                                .padding(2)
                        }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .black, design: .monospaced))
                        .tracking(1.5)
                    Text(subtitle)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1)
                        .opacity(0.6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(isOn ? Color.black : Color.botWhite)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(isOn ? Color.botGreen : Color.black.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(isOn ? Color.botGreen : Color.botChrome.opacity(0.35), lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

struct MetricBadge: View {
    let label: String
    let value: String
    var glow: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.botChrome.opacity(0.75))
            Text(value)
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundStyle(glow ? Color.botGreen : Color.botWhite)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke((glow ? Color.botGreen : Color.botChrome).opacity(0.35), lineWidth: 1))
    }
}

struct DataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(Color.botChrome.opacity(0.65))
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.botWhite.opacity(0.86))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct StatusLight: View {
    let label: String
    let color: Color
    let isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Color.botChrome.opacity(0.8))
            }
            Circle()
                .fill(isOn ? color : Color.botChromeDark)
                .frame(width: 10, height: 10)
                .shadow(color: isOn ? color.opacity(0.75) : Color.clear, radius: 8)
        }
    }
}

struct RetroBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.botBlack, Color(red: 0.045, green: 0.050, blue: 0.055), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            GeometryReader { geo in
                Path { path in
                    let step: CGFloat = 26
                    for x in stride(from: 0, through: geo.size.width, by: step) {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    }
                    for y in stride(from: 0, through: geo.size.height, by: step) {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    }
                }
                .stroke(Color.botChrome.opacity(0.035), lineWidth: 1)
            }
            .ignoresSafeArea()
        }
    }
}

struct ConsolePanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let cut: CGFloat = 18
        p.move(to: CGPoint(x: rect.minX + cut, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        p.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + cut, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - cut))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cut))
        p.closeSubpath()
        return p
    }
}
