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
    static let botAmber = Color(red: 1.0, green: 0.78, blue: 0.28)
}

// MARK: - Key Monitor

class KeyMonitor: ObservableObject {
    @Published var pressedKeys: Set<UInt16> = []

    var onDirectionEvent: ((String, Bool) -> Void)?

    private var monitor: Any?
    private let controlKeyCodes: Set<UInt16> = [12, 0, 31, 37, 6, 7]
    private let directionByKeyCode: [UInt16: String] = [
        12: "leftFootForward",   // Q
        0: "leftFootBack",       // A
        31: "rightFootForward",  // O
        37: "rightFootBack",     // L
        6: "weightShiftLeft",    // Z
        7: "weightShiftRight"    // X
    ]

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            guard self.controlKeyCodes.contains(event.keyCode) else { return event }

            let direction = self.directionByKeyCode[event.keyCode] ?? "stop"
            if event.type == .keyDown {
                let wasAlreadyDown = self.pressedKeys.contains(event.keyCode)
                self.pressedKeys.insert(event.keyCode)
                if !wasAlreadyDown { self.onDirectionEvent?(direction, true) }
            } else {
                self.pressedKeys.remove(event.keyCode)
                self.onDirectionEvent?(direction, false)
            }
            return nil
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    var isLeftFootForwardPressed: Bool { pressedKeys.contains(12) }
    var isLeftFootBackPressed: Bool { pressedKeys.contains(0) }
    var isRightFootForwardPressed: Bool { pressedKeys.contains(31) }
    var isRightFootBackPressed: Bool { pressedKeys.contains(37) }
    var isWeightShiftLeftPressed: Bool { pressedKeys.contains(6) }
    var isWeightShiftRightPressed: Bool { pressedKeys.contains(7) }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var robot = RobotControlService()
    @StateObject private var motionAI = MotionAIService()
    @StateObject private var keys = KeyMonitor()

    var body: some View {
        ZStack {
            RetroBackground()

            GeometryReader { proxy in
                let dashboardWidth: CGFloat = 1060
                let dashboardHeight: CGFloat = 880
                let scale = min(proxy.size.width / dashboardWidth, proxy.size.height / dashboardHeight, 1)

                DashboardCanvas(robot: robot, motionAI: motionAI, keys: keys)
                    .frame(width: dashboardWidth, height: dashboardHeight, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .center)
                    .frame(width: dashboardWidth * scale, height: dashboardHeight * scale)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
        }
        .frame(minWidth: 120, minHeight: 90)
        .onAppear {
            keys.onDirectionEvent = { direction, isDown in
                if isDown {
                    robot.send(direction: direction)
                } else if direction.hasPrefix("leftFoot") {
                    robot.send(direction: "leftFootStop")
                } else if direction.hasPrefix("rightFoot") {
                    robot.send(direction: "rightFootStop")
                } else if direction.hasPrefix("weightShift") {
                    robot.send(direction: "weightShiftStop")
                }
            }
        }
        .onDisappear {
            motionAI.stop()
            robot.stop()
        }
    }
}

// MARK: - Dashboard

struct DashboardCanvas: View {
    @ObservedObject var robot: RobotControlService
    @ObservedObject var motionAI: MotionAIService
    @ObservedObject var keys: KeyMonitor

    var body: some View {
        VStack(spacing: 12) {
            HeaderDeck()

            HStack(alignment: .top, spacing: 12) {
                ModelIOPanel(motionAI: motionAI)
                RobotOutputPanel(robot: robot, motionAI: motionAI)
            }

            LaunchSwitchBoard(
                rangeSoundOn: motionAI.useRangeSound,
                imuOn: motionAI.useIMU,
                aiOn: motionAI.isOn,
                rangeSoundToggle: { motionAI.useRangeSound.toggle() },
                imuToggle: { motionAI.useIMU.toggle() },
                aiToggle: {
                    motionAI.isOn ? motionAI.stop() : motionAI.start(robot: robot)
                }
            )

            HStack(spacing: 14) {
                FootControls(
                    leftForwardActive: keys.isLeftFootForwardPressed || motionAI.activeAction == "leftFootForward",
                    leftBackActive: keys.isLeftFootBackPressed || motionAI.activeAction == "leftFootBack",
                    rightForwardActive: keys.isRightFootForwardPressed || motionAI.activeAction == "rightFootForward",
                    rightBackActive: keys.isRightFootBackPressed || motionAI.activeAction == "rightFootBack",
                    leftForwardAction: { robot.pulse(direction: "leftFootForward") },
                    leftBackAction: { robot.pulse(direction: "leftFootBack") },
                    rightForwardAction: { robot.pulse(direction: "rightFootForward") },
                    rightBackAction: { robot.pulse(direction: "rightFootBack") }
                )

                WeightShiftControls(
                    shiftLeftActive: keys.isWeightShiftLeftPressed || motionAI.activeAction == "weightShiftLeft",
                    shiftRightActive: keys.isWeightShiftRightPressed || motionAI.activeAction == "weightShiftRight",
                    shiftLeftAction: { robot.pulse(direction: "weightShiftLeft") },
                    shiftRightAction: { robot.pulse(direction: "weightShiftRight") }
                )
            }
        }
        .padding(14)
        .frame(width: 1060, height: 880, alignment: .topLeading)
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

                Text("sensor data • MPU6050 IMU • GLM 5.1 fast actions")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(Color.botChrome.opacity(0.72))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                StatusLight(label: "SYSTEM", color: Color.botGreen, isOn: true)
                StatusLight(label: "GLM 5.1", color: Color.botGreen, isOn: true)
                StatusLight(label: "BOT LINK", color: Color.botGreen, isOn: true)
            }
        }
        .padding(14)
        .background(ConsolePanelShape().fill(Color.botPanel.opacity(0.90)))
        .overlay(ConsolePanelShape().stroke(Color.botChrome.opacity(0.38), lineWidth: 2))
    }
}

// MARK: - Model IO Panels

struct ModelIOPanel: View {
    @ObservedObject var motionAI: MotionAIService

    var body: some View {
        ConsolePanel(title: "MODEL INPUT WINDOW", subtitle: "sent to glm-5.1:cloud · think=false · 1hz") {
            VStack(alignment: .leading, spacing: 10) {
                DataRow(label: "MODEL", value: "glm-5.1:cloud · think=false · stream=false")
                DataRow(label: "FILES", value: "/tmp/littlebot_hcsr04.txt · /tmp/littlebot_sound.txt · /tmp/littlebot_mpu6050.json")
                ScrollTextBox(title: "INPUT SENT", text: motionAI.modelInput, height: 176)
                ScrollTextBox(title: "RAW OUTPUT", text: motionAI.modelOutput, height: 70)
            }
        }
        .frame(width: 672)
    }
}

struct RobotOutputPanel: View {
    @ObservedObject var robot: RobotControlService
    @ObservedObject var motionAI: MotionAIService

    var body: some View {
        ConsolePanel(title: "QUICK COMMAND", subtitle: motionAI.isOn ? "AI CONTROLLER ONLINE" : "AI CONTROLLER OFF") {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(Color.botChrome.opacity(0.25), lineWidth: 12)
                        .frame(width: 150, height: 150)
                    VStack(spacing: 4) {
                        Text(motionAI.lastCommand)
                            .font(.system(size: 34, weight: .black, design: .monospaced))
                            .minimumScaleFactor(0.45)
                            .lineLimit(1)
                            .foregroundStyle(motionAI.lastCommand == "—" ? Color.botChrome : Color.botGreen)
                        Text("ACTION")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(2)
                            .foregroundStyle(Color.botChrome.opacity(0.7))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    DataRow(label: "LATENCY", value: motionAI.lastLatencyMs > 0 ? "\(motionAI.lastLatencyMs)ms" : "—")
                    DataRow(label: "TICKS", value: "\(motionAI.ticks)")
                    DataRow(label: "ESP", value: robot.endpointDescription)
                    DataRow(label: "PACKETS", value: "\(robot.packetsSent)")
                }
            }
            .frame(maxWidth: 300)
        }
        .frame(width: 346)
    }
}

struct ScrollTextBox: View {
    let title: String
    let text: String
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.botChrome.opacity(0.7))
            ScrollView {
                Text(text)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.botWhite.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: height)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.botChrome.opacity(0.28), lineWidth: 1))
        }
    }
}

// MARK: - Switchboard + Controls

struct LaunchSwitchBoard: View {
    let rangeSoundOn: Bool
    let imuOn: Bool
    let aiOn: Bool
    let rangeSoundToggle: () -> Void
    let imuToggle: () -> Void
    let aiToggle: () -> Void

    var body: some View {
        ConsolePanel(title: "CONTROL SWITCHBOARD", subtitle: "fast sensor → model → action loop") {
            HStack(spacing: 14) {
                LaunchToggle(title: "RANGE/SOUND", subtitle: "HC-SR04 + SOUND", icon: "dot.radiowaves.left.and.right", isOn: rangeSoundOn, action: rangeSoundToggle)
                LaunchToggle(title: "MPU6050", subtitle: "GYRO / ACCEL", icon: "gyroscope", isOn: imuOn, action: imuToggle)
                LaunchToggle(title: "GLM WALKER", subtitle: "1HZ ACTION LOOP", icon: "brain.head.profile", isOn: aiOn, action: aiToggle)
            }
        }
    }
}

struct FootControls: View {
    let leftForwardActive: Bool
    let leftBackActive: Bool
    let rightForwardActive: Bool
    let rightBackActive: Bool
    let leftForwardAction: () -> Void
    let leftBackAction: () -> Void
    let rightForwardAction: () -> Void
    let rightBackAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FootPairPanel(title: "LEFT FOOT", forwardKey: "Q", backKey: "A", forwardActive: leftForwardActive, backActive: leftBackActive, forwardAction: leftForwardAction, backAction: leftBackAction)
            FootPairPanel(title: "RIGHT FOOT", forwardKey: "O", backKey: "L", forwardActive: rightForwardActive, backActive: rightBackActive, forwardAction: rightForwardAction, backAction: rightBackAction)
        }
    }
}

struct FootPairPanel: View {
    let title: String
    let forwardKey: String
    let backKey: String
    let forwardActive: Bool
    let backActive: Bool
    let forwardAction: () -> Void
    let backAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .tracking(1.2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(Color.botWhite)
                .frame(width: 102, alignment: .leading)

            FootButton(title: "FWD", key: forwardKey, isActive: forwardActive, action: forwardAction)
            FootButton(title: "BACK", key: backKey, isActive: backActive, action: backAction)
        }
        .padding(12)
        .background(Color.botPanel2)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.botChrome.opacity(0.45), lineWidth: 2))
    }
}

struct WeightShiftControls: View {
    let shiftLeftActive: Bool
    let shiftRightActive: Bool
    let shiftLeftAction: () -> Void
    let shiftRightAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("WEIGHT")
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.botWhite)
                .frame(width: 72, alignment: .leading)

            FootButton(title: "LEFT", key: "Z", isActive: shiftLeftActive, action: shiftLeftAction)
            FootButton(title: "RIGHT", key: "X", isActive: shiftRightActive, action: shiftRightAction)
        }
        .padding(12)
        .background(Color.botPanel2)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.botChrome.opacity(0.45), lineWidth: 2))
    }
}

struct FootButton: View {
    let title: String
    let key: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(key)
                    .font(.system(size: 24, weight: .heavy, design: .monospaced))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("ESP UDP")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .opacity(0.65)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isActive ? Color.black : Color.botWhite)
            .padding(.horizontal, 12)
            .frame(width: 96, height: 58)
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
                StatusLight(label: "", color: Color.botGreen, isOn: subtitle.uppercased().contains("ON") || subtitle.uppercased().contains("GLM") || subtitle.uppercased().contains("1HZ"))
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

struct DataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundStyle(Color.botChrome.opacity(0.65))
                .frame(width: 86, alignment: .leading)
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
