import AppKit
import AVFoundation
import CaptionsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private let originalLabel = NSTextField(labelWithString: "말을 시작하면 원문이 여기에 표시됩니다")
    private let translatedLabel = NSTextField(labelWithString: "Your translation will appear here")
    private let statusLabel = NSTextField(labelWithString: "준비 중…")
    private let toggleButton = NSButton(title: "시작", target: nil, action: nil)
    private let clearButton = NSButton(title: "지우기", target: nil, action: nil)
    private let quitButton = NSButton(title: "종료", target: nil, action: nil)
    private let languageButton = NSButton(title: "자동", target: nil, action: nil)
    private let controller = PipelineController(pipeline: SpeechPipeline())
    private let translator = Translator(table: .default)
    private var running = false
    private var clearWork: DispatchWorkItem?
    /// 발화 ID는 파이프라인이 매기는 Int(`TranscriptEvent.utteranceID`)이지만 Translator는
    /// 자막 목록(Task 7)을 염두에 두고 UUID를 쓴다. 여기서 Int → UUID로 다리를 놓는다.
    /// 같은 utteranceID가 이어지는 동안(부분 → 확정 갱신)은 같은 UUID를 유지한다.
    private var currentUtteranceID: Int?
    private var currentCaptionID = UUID()
    /// 자동 모드는 실험 기능이다. 최초 언어는 한국어, 고정 모드는 저장한 ID를 쓴다.
    private var languageMode: LanguageMode = .fixed(CaptionLanguage.korean.id)
    private var currentLanguage: CaptionLanguage = .korean
    private var sensitivity: DetectorSensitivity = .medium
    private var audioSourceKind: AudioSourceKind = .microphone
    private var captionHoldSeconds: Double = 10
    private var latestCaption = LatestCaption()

    /// 설정에서 만든 소스·언어·민감도의 스냅샷. 모든 시작/재구성이 이 경로를 지난다.
    private var currentConfiguration: PipelineConfiguration {
        PipelineConfiguration(source: audioSourceKind, language: currentLanguage, sensitivity: sensitivity)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        bindController()
        requestPermissionsAndStart()
    }

    private func bindController() {
        applyStoredSettings()
        controller.onState = { [weak self] state in self?.apply(state) }
        controller.onEvent = { [weak self] event in self?.handle(event) }
        translator.onTranslation = { [weak self] text, refined, captionID in
            guard let self, captionID == self.currentCaptionID else { return } // 늦게 온 응답 폐기
            if refined {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    self.translatedLabel.animator().alphaValue = 0
                } completionHandler: {
                    // 애니메이션이 도는 동안 표시된 발화가 바뀌었을 수 있다 — 다시 검사한다.
                    guard captionID == self.currentCaptionID else { return }
                    self.translatedLabel.stringValue = text
                    self.translatedLabel.animator().alphaValue = 1
                }
            } else {
                self.translatedLabel.stringValue = text
            }
        }
    }

    /// 파이프라인의 Int `utteranceID`를 Translator의 UUID `captionID`로 바꾼다.
    /// 같은 발화(같은 utteranceID)가 이어지는 동안에는 같은 UUID를 유지해서
    /// 부분→확정 갱신이 같은 줄로 취급되게 한다. 발화가 바뀌면 새 UUID를 발급한다.
    private func captionID(for utteranceID: Int) -> UUID {
        if utteranceID != currentUtteranceID {
            currentUtteranceID = utteranceID
            currentCaptionID = UUID()
        }
        return currentCaptionID
    }

    /// 저장된 설정에서 언어·소스·민감도를 읽어 온다. 고정 모드의 ID가 곧 시작 언어이고,
    /// 자동 모드의 최초 언어는 한국어다.
    private func applyStoredSettings() {
        let settings = Settings.load(from: .standard)
        languageMode = settings.languageMode
        audioSourceKind = settings.audioSource
        sensitivity = settings.detectorSensitivity
        captionHoldSeconds = settings.captionHoldSeconds
        if case .fixed(let id) = settings.languageMode,
           let language = LanguageTable.default.language(id: id) {
            currentLanguage = language
        } else {
            currentLanguage = .korean
        }
        languageButton.title = languageButtonTitle
    }

    /// running과 버튼 상태는 controller의 상태 하나에서 함께 갱신한다.
    /// 시작 요청을 보냈다고 곧바로 "듣는 중"으로 바꾸지 않는다.
    private func apply(_ state: PipelineController.State) {
        switch state {
        case .stopped:
            running = false
            toggleButton.title = "시작"
            statusLabel.stringValue = "일시 정지"
        case .starting:
            running = true
            toggleButton.title = "정지"
            statusLabel.stringValue = "음성 엔진 시작 중…"
        case .listening:
            running = true
            toggleButton.title = "정지"
            updateListeningStatus()
        case .stopping:
            toggleButton.title = "정지 중…"
        case .failed(let message):
            running = false
            toggleButton.title = "다시 시작"
            statusLabel.stringValue = "시작 실패: \(message)"
        }
        toggleButton.isEnabled = true
    }

    private func handle(_ event: PipelineEvent) {
        switch event.kind {
        case .installing(let fraction):
            let percent = max(0, min(100, Int(fraction * 100)))
            statusLabel.stringValue = "음성 모델 설치 중 · \(percent)%"
        case .listening(let language):
            currentLanguage = language
            updateListeningStatus()
        case .transcript(let transcript):
            show(transcript)
        case .failed:
            break // 상태 콜백이 메시지를 이미 보여준다
        }
    }

    private func show(_ event: TranscriptEvent) {
        // 옛 발화의 뒤늦은 final이 최신 원문을 되돌리지 않게 발화 ID로 거른다.
        guard let text = latestCaption.apply(event) else { return }
        let captionID = captionID(for: event.utteranceID)
        let displayed = CaptionText.tail(text)
        originalLabel.stringValue = displayed
        // 원문을 갱신할 때 이전 번역 표시도 비우고 새 요청을 등록한다.
        translatedLabel.stringValue = ""
        translator.submit(event.transcript, from: event.sourceLanguage, captionID: captionID)
        // 말이 이어지는 동안에는 지우기 타이머를 계속 뒤로 민다.
        scheduleCaptionClear()

        if case .auto = languageMode, event.isFinal {
            proposeAutomaticLanguage(for: text)
        }
    }

    /// 자동 전환은 실험 기능이다. 제안만 하고 실행은 반드시 controller를 거친다.
    ///
    /// 여기서 translator.reset()을 부르지 않는다: 이 함수는 방금 이 이벤트에 대해
    /// submit()이 이미 끝난 뒤에 호출된다(위 show() 참고). 그 submit은 이벤트에 고정된
    /// event.sourceLanguage를 썼으므로 이미 올바르다 — reset()을 부르면 방금 막 등록한
    /// 정당한 번역 요청 자체를 취소해버린다. currentLanguage는 다음 발화의 인식 엔진
    /// 설정에만 영향을 주고, 다음 발화는 어차피 새 captionID로 새 submit()을 타므로
    /// 이전 세대는 자연히 무효화된다.
    private func proposeAutomaticLanguage(for text: String) {
        let detected = LanguageTable.default.detect(text, current: currentLanguage)
        guard detected != currentLanguage else { return }
        currentLanguage = detected
        controller.requestReconfigure(configuration: currentConfiguration)
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
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.statusLabel.stringValue = "마이크 권한이 필요합니다"
                    self?.toggleButton.isEnabled = false
                    return
                }
                self?.startListening()
            }
        }
    }

    @objc private func toggleListening() {
        running ? stopListening() : startListening()
    }

    @objc private func clearCaptions() {
        originalLabel.stringValue = ""
        translatedLabel.stringValue = ""
        invalidateCaptions()
    }

    /// 진행 중인 번역 작업과 clear 타이머를 취소한다.
    private func invalidateCaptions() {
        clearWork?.cancel()
        clearWork = nil
        translator.reset()
        latestCaption.reset()
        currentUtteranceID = nil
    }

    @objc private func quitApp() {
        stopListening()
        NSApp.terminate(nil)
    }

    /// 수동 한국어/영어 전환과 설정의 fixed ID가 같은 configuration 경로를 탄다.
    @objc private func switchLanguage() {
        switch languageMode {
        case .auto:
            languageMode = .fixed(CaptionLanguage.korean.id)
            currentLanguage = .korean
        case .fixed(let id) where id == CaptionLanguage.korean.id:
            languageMode = .fixed(CaptionLanguage.english.id)
            currentLanguage = .english
        case .fixed:
            languageMode = .auto
            currentLanguage = .korean
        }
        languageButton.title = languageButtonTitle
        if running {
            translator.reset() // 언어쌍이 바뀌므로 진행 중이던 번역·보정은 무효화한다.
            controller.requestReconfigure(configuration: currentConfiguration)
        }
    }

    private var languageButtonTitle: String {
        switch languageMode {
        case .auto: "자동 (실험)"
        case .fixed(let id): LanguageTable.default.language(id: id)?.displayName ?? id
        }
    }

    private func startListening() {
        controller.requestStart(configuration: currentConfiguration)
    }

    private func stopListening() {
        invalidateCaptions()
        controller.requestStop()
    }

    private func updateListeningStatus() {
        let mode: String
        switch languageMode {
        case .auto: mode = "자동 (실험) · \(currentLanguage.displayName)"
        case .fixed: mode = currentLanguage.displayName
        }
        statusLabel.stringValue = "● 듣는 중 · \(mode)"
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
                self.translator.reset() // 유지 시간 만료로 자막을 비운다 — 대기 중이던 번역도 무효화.
                self.latestCaption.reset()
                self.currentUtteranceID = nil
            }
        }
        clearWork = work
        // 발화마다 지우지 않는다. 침묵이 captionHoldSeconds 만큼 이어진 뒤에만 비운다.
        DispatchQueue.main.asyncAfter(deadline: .now() + captionHoldSeconds, execute: work)
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
