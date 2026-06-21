import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class AssistantService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isOn = false
    @Published private(set) var isStarting = false
    @Published private(set) var isListening = false
    @Published private(set) var isThinking = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var heardCount = 0
    @Published private(set) var lastStatement: String = ""
    @Published private(set) var statusText: String = "Off"

    private let mossHost = URL(string: "http://127.0.0.1:7860")!
    private let ollamaChatURL = URL(string: "http://127.0.0.1:11434/v1/chat/completions")!
    private let model = "glm-5.2:cloud"
    private let assistantInterval: TimeInterval = 300
    private let systemPrompt = "You are Woody from Toy Story. What's your take on this situation? Respond as one short spoken statement. No markdown. No emojis."

    private let mossRoot = URL(fileURLWithPath: "/Users/maxrippley/moss-tts-local/MOSS-TTS-Nano", isDirectory: true)
    private let mossPython = URL(fileURLWithPath: "/Users/maxrippley/moss-tts-local/venv/bin/python")
    private let mossApp = URL(fileURLWithPath: "/Users/maxrippley/moss-tts-local/MOSS-TTS-Nano/app_local.py")

    private var mossProcess: Process?
    private var timer: Timer?
    private var context: [HeardItem] = []

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false

    private var audioPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        // Assistant starts in OFF state. Enforce that state even if a previous
        // manual/test MOSS process was left running on localhost:7860.
        terminateMossHelper()
    }

    private struct HeardItem {
        let date: Date
        let text: String
    }

    var detail: String {
        if isStarting { return "Starting voice + listener…" }
        if !isOn { return "Off" }
        if isThinking { return "Thinking · \(heardCount) snippets" }
        if isSpeaking { return "Speaking · \(heardCount) snippets" }
        if isListening { return "Listening · \(heardCount) snippets · 5 min loop" }
        return statusText
    }

    func start() {
        guard !isOn && !isStarting else { return }
        clearContext()
        isStarting = true
        statusText = "Starting MOSS helper…"

        Task {
            do {
                try await ensureMossRunning()
                statusText = "Requesting microphone…"
                let authorized = await requestSpeechPermissions()
                guard authorized else {
                    statusText = "Mic/Speech permission denied"
                    isStarting = false
                    return
                }

                isOn = true
                isStarting = false
                statusText = "Listening · 5 min loop"
                startListeningLoop()
                startAssistantTimer()
            } catch {
                statusText = "Start failed: \(error.localizedDescription)"
                isStarting = false
                isOn = false
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopListening()
        audioPlayer?.stop()
        audioPlayer = nil
        playbackContinuation?.resume()
        playbackContinuation = nil
        isSpeaking = false
        isThinking = false
        isStarting = false
        isOn = false
        statusText = "Off"
        clearContext()
        terminateMossHelper()
    }

    // MARK: - MOSS helper

    private func ensureMossRunning() async throws {
        if await mossHealthOK() { return }

        guard FileManager.default.fileExists(atPath: mossPython.path) else {
            throw NSError(domain: "Assistant", code: 1, userInfo: [NSLocalizedDescriptionKey: "MOSS Python not found at \(mossPython.path)"])
        }
        guard FileManager.default.fileExists(atPath: mossApp.path) else {
            throw NSError(domain: "Assistant", code: 2, userInfo: [NSLocalizedDescriptionKey: "MOSS app_local.py not found"])
        }

        let process = Process()
        process.executableURL = mossPython
        process.arguments = [mossApp.path]
        process.currentDirectoryURL = mossRoot

        var env = ProcessInfo.processInfo.environment
        env["SAMPLE_MODE"] = "full"
        env["STREAMING_DECODE"] = "1"
        env["MAX_NEW_FRAMES"] = "500"
        env["CPU_THREADS"] = "4"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let logPath = "/tmp/littlerip-moss-helper.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        if let log = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            process.standardOutput = log
            process.standardError = log
        }

        try process.run()
        mossProcess = process

        for _ in 0..<30 {
            if await mossHealthOK() { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw NSError(domain: "Assistant", code: 3, userInfo: [NSLocalizedDescriptionKey: "MOSS helper did not become ready"])
    }

    private func mossHealthOK() async -> Bool {
        var request = URLRequest(url: mossHost.appendingPathComponent("health"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func terminateMossHelper() {
        if let process = mossProcess, process.isRunning {
            process.terminate()
        }
        mossProcess = nil

        // If the server was already running before the app launched, stop the
        // process bound to 7860 so toggle OFF means fully off for this setup.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-lc", "lsof -ti tcp:7860 | xargs kill 2>/dev/null || true"]
        try? shell.run()
    }

    // MARK: - Speech recognition

    private func requestSpeechPermissions() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { speechStatus in
                AVAudioApplication.requestRecordPermission { micAllowed in
                    continuation.resume(returning: speechStatus == .authorized && micAllowed)
                }
            }
        }
    }

    private func startListeningLoop() {
        guard isOn && !isThinking && !isSpeaking else { return }
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            statusText = "Speech recognizer unavailable"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true

        var didDeliverFinal = false
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal && !didDeliverFinal {
                        didDeliverFinal = true
                        self.addContext(text)
                        self.stopListening()
                        self.restartListeningSoon()
                    }
                }

                if error != nil && self.isOn && !self.isThinking && !self.isSpeaking {
                    self.stopListening()
                    self.restartListeningSoon()
                }
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            statusText = "Listening · 5 min loop"
        } catch {
            statusText = "Mic start failed: \(error.localizedDescription)"
        }
    }

    private func stopListening() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        isListening = false
    }

    private func restartListeningSoon() {
        guard isOn && !isThinking && !isSpeaking else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.startListeningLoop()
        }
    }

    private func addContext(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return }
        if context.last?.text == trimmed { return }
        context.append(HeardItem(date: Date(), text: trimmed))
        if context.count > 500 { context.removeFirst(context.count - 500) }
        heardCount = context.count
    }

    private func clearContext() {
        context.removeAll()
        heardCount = 0
    }

    // MARK: - 5-minute assistant loop

    private func startAssistantTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: assistantInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.makeTimedStatement() }
        }
    }

    private func makeTimedStatement() async {
        guard isOn && !isThinking && !isSpeaking else { return }
        guard !context.isEmpty else {
            statusText = "Listening · no context yet"
            return
        }

        isThinking = true
        statusText = "Thinking…"
        stopListening()

        do {
            let statement = try await askGLMForStatement()
            let spoken = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spoken.isEmpty else {
                clearContext()
                isThinking = false
                restartListeningSoon()
                return
            }

            lastStatement = spoken
            isThinking = false
            isSpeaking = true
            statusText = "Speaking…"
            let wav = try await synthesizeWithMoss(text: spoken)
            try await playWAV(wav)
            clearContext()
            isSpeaking = false
            statusText = "Listening · 5 min loop"
            restartListeningSoon()
        } catch {
            isThinking = false
            isSpeaking = false
            statusText = "Assistant error: \(error.localizedDescription)"
            restartListeningSoon()
        }
    }

    private func contextWindowText() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let joined = context.suffix(120).map { "[\(formatter.string(from: $0.date))] \($0.text)" }.joined(separator: "\n")
        return String(joined.suffix(100_000))
    }

    private func askGLMForStatement() async throws -> String {
        struct Message: Encodable { let role: String; let content: String }
        struct RequestBody: Encodable { let model: String; let messages: [Message]; let stream: Bool }
        struct ResponseBody: Decodable { let choices: [Choice] }
        struct Choice: Decodable { let message: ResponseMessage }
        struct ResponseMessage: Decodable { let content: String? }

        let userContext = "Recent passive microphone context:\n\n\(contextWindowText())\n\nGive your take on this situation as a short spoken statement."
        let body = RequestBody(
            model: model,
            messages: [
                Message(role: "system", content: systemPrompt),
                Message(role: "user", content: userContext)
            ],
            stream: false
        )

        var request = URLRequest(url: ollamaChatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? "Unknown LLM error"
            throw NSError(domain: "Assistant", code: 10, userInfo: [NSLocalizedDescriptionKey: text])
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    private func synthesizeWithMoss(text: String) async throws -> Data {
        struct SpeakRequest: Encodable { let text: String }
        var request = URLRequest(url: mossHost.appendingPathComponent("speak"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONEncoder().encode(SpeakRequest(text: text))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let text = String(data: data, encoding: .utf8) ?? "Unknown MOSS error"
            throw NSError(domain: "Assistant", code: 20, userInfo: [NSLocalizedDescriptionKey: text])
        }
        return data
    }

    private func playWAV(_ data: Data) async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("littlerip-assistant-\(UUID().uuidString).wav")
        try data.write(to: url)

        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        audioPlayer = player
        player.prepareToPlay()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playbackContinuation = continuation
            if !player.play() {
                playbackContinuation = nil
                continuation.resume()
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            playbackContinuation?.resume()
            playbackContinuation = nil
            audioPlayer = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            playbackContinuation?.resume()
            playbackContinuation = nil
            audioPlayer = nil
        }
    }
}
