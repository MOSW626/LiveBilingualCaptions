import AppKit
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private let originalLabel = NSTextField(labelWithString: "말을 시작하면 원문이 여기에 표시됩니다")
    private let translatedLabel = NSTextField(labelWithString: "Your translation will appear here")
    private let statusLabel = NSTextField(labelWithString: "준비 중…")
    private let toggleButton = NSButton(title: "시작", target: nil, action: nil)
    private let clearButton = NSButton(title: "지우기", target: nil, action: nil)
    private let quitButton = NSButton(title: "종료", target: nil, action: nil)
    private let languageButton = NSButton(title: "자동", target: nil, action: nil)
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: DictationTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var legacyRecognizer: SFSpeechRecognizer?
    private var legacyRequest: SFSpeechAudioBufferRecognitionRequest?
    private var legacyTask: SFSpeechRecognitionTask?
    private var running = false
    private var translateWork: DispatchWorkItem?
    private var pendingTranslationText = ""
    private var lastTranslationStartedAt = Date.distantPast
    private var clearWork: DispatchWorkItem?
    private var lastTranslatedSource = ""
    private var recognitionLocaleIdentifier = "ko-KR"
    private var languageMode = "auto"
    private var latestRecognizedText = ""
    private var latestRecognitionConfidence: Float = 0
    private var lastVoiceAt = Date.distantPast
    private var speechActive = false
    private var silenceTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        requestPermissionsAndStart()
    }

    private func buildWindow() {
        let size = NSSize(width: 560, height: 188)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless],
                        backing: .buffered, defer: false)
        // Keep captions above normal windows, presentations, and full-screen apps.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.center()
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.minY + 54
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 20
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        originalLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        originalLabel.textColor = .white
        originalLabel.maximumNumberOfLines = 2
        originalLabel.lineBreakMode = .byTruncatingHead
        originalLabel.alignment = .center
        originalLabel.translatesAutoresizingMaskIntoConstraints = false

        translatedLabel.font = .systemFont(ofSize: 16, weight: .medium)
        translatedLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        translatedLabel.maximumNumberOfLines = 2
        translatedLabel.lineBreakMode = .byTruncatingHead
        translatedLabel.alignment = .center
        translatedLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.52)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.target = self
        toggleButton.action = #selector(toggleListening)
        toggleButton.bezelStyle = .rounded
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.target = self
        clearButton.action = #selector(clearCaptions)
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        languageButton.target = self
        languageButton.action = #selector(switchLanguage)
        languageButton.bezelStyle = .rounded
        languageButton.translatesAutoresizingMaskIntoConstraints = false
        quitButton.target = self
        quitButton.action = #selector(quitApp)
        quitButton.bezelStyle = .rounded
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        [originalLabel, translatedLabel, statusLabel, languageButton, toggleButton, clearButton, quitButton].forEach(effect.addSubview)
        NSLayoutConstraint.activate([
            originalLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 26),
            originalLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -26),
            originalLabel.topAnchor.constraint(equalTo: effect.topAnchor, constant: 18),
            translatedLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 26),
            translatedLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -26),
            translatedLabel.topAnchor.constraint(equalTo: originalLabel.bottomAnchor, constant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            statusLabel.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -13),
            quitButton.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            quitButton.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
            quitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 66),
            quitButton.heightAnchor.constraint(equalToConstant: 40),
            clearButton.trailingAnchor.constraint(equalTo: quitButton.leadingAnchor, constant: -8),
            clearButton.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
            clearButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            clearButton.heightAnchor.constraint(equalToConstant: 40),
            toggleButton.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            toggleButton.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
            toggleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            toggleButton.heightAnchor.constraint(equalToConstant: 40),
            languageButton.trailingAnchor.constraint(equalTo: toggleButton.leadingAnchor, constant: -8),
            languageButton.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -8),
            languageButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 82),
            languageButton.heightAnchor.constraint(equalToConstant: 40)
        ])
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func requestPermissionsAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async {
                    guard auth == .authorized, mic else {
                        self?.statusLabel.stringValue = "마이크와 음성 인식 권한이 필요합니다"
                        self?.toggleButton.isEnabled = false
                        return
                    }
                    self?.startListening()
                }
            }
        }
    }

    @objc private func toggleListening() {
        running ? stopListening() : startListening()
    }

    @objc private func clearCaptions() {
        originalLabel.stringValue = ""
        translatedLabel.stringValue = ""
        clearWork?.cancel()
        lastTranslatedSource = ""
    }

    @objc private func quitApp() {
        stopListening()
        NSApp.terminate(nil)
    }

    @objc private func switchLanguage() {
        if languageMode == "auto" {
            languageMode = "ko"
            recognitionLocaleIdentifier = "ko-KR"
            languageButton.title = "한국어"
        } else if languageMode == "ko" {
            languageMode = "en"
            recognitionLocaleIdentifier = "en-US"
            languageButton.title = "English"
        } else {
            languageMode = "auto"
            recognitionLocaleIdentifier = "ko-KR"
            languageButton.title = "자동"
        }
        clearCaptions()
        if running {
            stopListening()
            startListening()
        }
    }

    private func startListening() {
        guard !running else { return }
        running = true
        toggleButton.title = "정지"
        statusLabel.stringValue = "기존 음성 엔진 시작 중…"
        startLegacyTranscription()
    }

    private func startLegacyTranscription() {
        do {
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: recognitionLocaleIdentifier))
            guard let recognizer, recognizer.isAvailable else {
                throw NSError(domain: "Captions", code: 10, userInfo: [NSLocalizedDescriptionKey: "macOS 음성 인식 서비스를 사용할 수 없습니다"])
            }
            legacyRecognizer = recognizer
            beginLegacyRecognitionTask()

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                throw NSError(domain: "Captions", code: 11, userInfo: [NSLocalizedDescriptionKey: "마이크 입력을 찾지 못했습니다"])
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                self?.legacyRequest?.append(buffer)
                guard let channel = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                guard count > 0 else { return }
                var sum: Float = 0
                for index in stride(from: 0, to: count, by: 4) { sum += channel[index] * channel[index] }
                let rms = sqrt(sum / Float(max(1, count / 4)))
                if rms > 0.0035 {
                    DispatchQueue.main.async { self?.voiceDetected() }
                }
            }
            audioEngine.prepare()
            try audioEngine.start()
            updateListeningStatus()
            silenceTimer?.invalidate()
            silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.checkForSilence()
            }
        } catch {
            statusLabel.stringValue = "시작 실패: \(error.localizedDescription)"
            running = false
            toggleButton.title = "다시 시작"
        }
    }

    private func beginLegacyRecognitionTask() {
        guard let recognizer = legacyRecognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = ["English", "Korean", "PowerPoint", "presentation", "individual", "team"]
        legacyRequest = request
        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        self?.latestRecognizedText = text
                        let displayedText = self?.captionTail(text) ?? text
                        self?.originalLabel.stringValue = displayedText
                        let segments = result.bestTranscription.segments
                        self?.latestRecognitionConfidence = segments.isEmpty ? 0 : segments.map(\.confidence).reduce(0, +) / Float(segments.count)
                        self?.scheduleTranslation(of: displayedText)
                    }
                }
                if let error, self?.running == true {
                    self?.statusLabel.stringValue = "인식 오류: \(error.localizedDescription)"
                }
            }
        }
    }

    private func voiceDetected() {
        lastVoiceAt = Date()
        if !speechActive {
            speechActive = true
            clearWork?.cancel()
            originalLabel.stringValue = ""
            translatedLabel.stringValue = ""
            lastTranslatedSource = ""
            latestRecognizedText = ""
            latestRecognitionConfidence = 0
        }
    }

    private func checkForSilence() {
        guard running, speechActive, Date().timeIntervalSince(lastVoiceAt) > 1.15 else { return }
        speechActive = false
        legacyRequest?.endAudio()
        legacyTask?.finish()
        scheduleCaptionClear()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard self?.running == true else { return }
            self?.adaptLanguageForNextUtterance()
            self?.beginLegacyRecognitionTask()
        }
    }

    private func adaptLanguageForNextUtterance() {
        guard languageMode == "auto" else { return }
        let scalars = latestRecognizedText.unicodeScalars
        let hangulCount = scalars.filter { (0xAC00...0xD7A3).contains(Int($0.value)) }.count
        let latinCount = scalars.filter {
            (0x41...0x5A).contains(Int($0.value)) || (0x61...0x7A).contains(Int($0.value))
        }.count
        let nextLocale: String
        if hangulCount > 0 {
            nextLocale = "ko-KR"
        } else if latinCount >= 3 {
            nextLocale = recognitionLocaleIdentifier == "en-US" && latestRecognitionConfidence < 0.28 ? "ko-KR" : "en-US"
        } else {
            nextLocale = recognitionLocaleIdentifier == "en-US" ? "ko-KR" : recognitionLocaleIdentifier
        }
        if nextLocale != recognitionLocaleIdentifier {
            recognitionLocaleIdentifier = nextLocale
            legacyRecognizer = SFSpeechRecognizer(locale: Locale(identifier: nextLocale))
        }
        updateListeningStatus()
    }

    private func updateListeningStatus() {
        let active = recognitionLocaleIdentifier == "ko-KR" ? "KO" : "EN"
        let mode = languageMode == "auto" ? "자동 \(active)" : (active == "KO" ? "한국어" : "English")
        statusLabel.stringValue = "● 듣는 중 · \(mode) · 회의 모드"
    }

    @available(macOS 26.0, *)
    private func startModernTranscription() async {
        do {
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "ko-KR")) else {
                throw NSError(domain: "Captions", code: 2, userInfo: [NSLocalizedDescriptionKey: "한국어 전사 모델을 지원하지 않습니다"])
            }
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: [.farField],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: []
            )
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                let progress = install.progress
                let progressTask = Task { [weak self] in
                    while !Task.isCancelled && !progress.isFinished {
                        let percent = max(0, min(100, Int(progress.fractionCompleted * 100)))
                        await MainActor.run {
                            self?.statusLabel.stringValue = "음성 모델 설치 중 · \(percent)%"
                        }
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                }
                try await install.downloadAndInstall()
                progressTask.cancel()
            }
            await MainActor.run { self.statusLabel.stringValue = "음성 엔진 시작 중…" }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw NSError(domain: "Captions", code: 3, userInfo: [NSLocalizedDescriptionKey: "호환되는 마이크 형식을 찾지 못했습니다"])
            }
            let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.prepareToAnalyze(in: format)

            await MainActor.run {
                self.transcriber = transcriber
                self.analyzer = analyzer
                self.inputContinuation = continuation
                let input = self.audioEngine.inputNode
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                    continuation.yield(AnalyzerInput(buffer: buffer))
                }
                self.audioEngine.prepare()
            }
            try await audioEngine.start()
            await MainActor.run { self.statusLabel.stringValue = "● 듣는 중 · 한국어 + English 혼용" }

            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        await MainActor.run {
                            self?.originalLabel.stringValue = text
                            self?.scheduleTranslation(of: text)
                            self?.scheduleCaptionClear()
                        }
                    }
                } catch {
                    await MainActor.run { self?.statusLabel.stringValue = "전사 오류: \(error.localizedDescription)" }
                }
            }
            analysisTask = Task { [weak self] in
                do { _ = try await analyzer.analyzeSequence(stream) }
                catch { await MainActor.run { self?.statusLabel.stringValue = "분석 오류: \(error.localizedDescription)" } }
            }
        } catch {
            await MainActor.run {
                self.statusLabel.stringValue = "시작 실패: \(error.localizedDescription)"
                self.running = false
                self.toggleButton.title = "다시 시작"
            }
        }
    }

    private func stopListening() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        legacyRequest?.endAudio()
        legacyTask?.cancel()
        legacyRequest = nil; legacyTask = nil; legacyRecognizer = nil
        silenceTimer?.invalidate(); silenceTimer = nil
        speechActive = false
        inputContinuation?.finish()
        inputContinuation = nil
        analysisTask?.cancel(); resultsTask?.cancel()
        analysisTask = nil; resultsTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil; transcriber = nil
        running = false
        toggleButton.title = "시작"
        statusLabel.stringValue = "일시 정지"
    }

    private func scheduleTranslation(of text: String) {
        guard text != lastTranslatedSource else { return }
        pendingTranslationText = text
        guard translateWork == nil else { return }
        let elapsed = Date().timeIntervalSince(lastTranslationStartedAt)
        let delay = max(0, 0.22 - elapsed)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.translateWork = nil
            let current = self.pendingTranslationText
            self.lastTranslationStartedAt = Date()
            self.translate(current)
        }
        translateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func captionTail(_ text: String) -> String {
        let limit = 92
        guard text.count > limit else { return text }
        let suffix = String(text.suffix(limit))
        if let space = suffix.firstIndex(where: { $0 == " " }) {
            return "…" + suffix[suffix.index(after: space)...]
        }
        return "…" + suffix
    }

    private func scheduleCaptionClear() {
        clearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self.originalLabel.animator().alphaValue = 0
                self.translatedLabel.animator().alphaValue = 0
            } completionHandler: {
                self.originalLabel.stringValue = ""
                self.translatedLabel.stringValue = ""
                self.originalLabel.alphaValue = 1
                self.translatedLabel.alphaValue = 1
                self.lastTranslatedSource = ""
            }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: work)
    }

    private func translate(_ text: String) {
        let hasKorean = text.unicodeScalars.contains { (0xAC00...0xD7A3).contains(Int($0.value)) }
        let target = hasKorean ? "en" : "ko"
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target), URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components.url else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let blocks = json.first as? [Any] else { return }
            let translated = blocks.compactMap { ($0 as? [Any])?.first as? String }.joined()
            DispatchQueue.main.async {
                guard !translated.isEmpty, self?.originalLabel.stringValue == text else { return }
                self?.lastTranslatedSource = text
                self?.translatedLabel.stringValue = translated
                if let pending = self?.pendingTranslationText, pending != text {
                    self?.scheduleTranslation(of: pending)
                }
            }
        }.resume()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct LiveBilingualCaptionsMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        _ = delegate
    }
}
