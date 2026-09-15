import AppKit
import AVFoundation
import SwiftUI
import CaptionsCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private let state = CaptionState()
    private let controller = PipelineController(pipeline: SpeechPipeline(makeSource: { kind in
        switch kind {
        case .microphone: MicSource()
        case .systemAudio: SystemAudioSource()
        }
    }))
    private let translator = Translator(table: .default)
    private var settings = Settings.default
    private var running = false
    private var clearTask: Task<Void, Never>?
    /// 자동 모드는 실험 기능이다. 최초 언어는 한국어, 고정 모드는 저장한 ID를 쓴다.
    private var languageMode: LanguageMode = .fixed(CaptionLanguage.korean.id) {
        didSet { syncLanguage() }
    }
    private var currentLanguage: CaptionLanguage = .korean {
        didSet { syncLanguage() }
    }
    private var sensitivity: DetectorSensitivity = .medium
    private var audioSourceKind: AudioSourceKind = .microphone
    private var captionHoldSeconds: Double = 10

    /// 설정에서 만든 소스·언어·민감도의 스냅샷. 모든 시작/재구성이 이 경로를 지난다.
    private var currentConfiguration: PipelineConfiguration {
        PipelineConfiguration(source: audioSourceKind, language: currentLanguage, sensitivity: sensitivity)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyStoredSettings()
        buildWindow()
        bindController()
        requestPermissionsAndStart()
    }

    private func bindController() {
        controller.onState = { [weak self] state in self?.apply(state) }
        controller.onEvent = { [weak self] event in self?.handle(event) }
        // 늦게 온 번역이라도 자기 발화 줄에 붙인다 — 이제 옛 줄도 화면에 남아 있으므로
        // 버리는 게 아니라 라우팅이 맞다. 이미 밀려난 줄이면 setTranslation 이 무시한다.
        // 보정본 교차 페이드는 CaptionOverlay 의 .animation(value: entry.translated) 이 맡는다.
        translator.onTranslation = { [weak self] text, _, captionID in
            self?.state.setTranslation(text, for: captionID)
        }
    }

    /// 저장된 설정에서 언어·소스·민감도를 읽어 온다. 고정 모드의 ID가 곧 시작 언어이고,
    /// 자동 모드의 최초 언어는 한국어다.
    private func applyStoredSettings() {
        settings = Settings.load(from: .standard)
        audioSourceKind = settings.audioSource
        state.audioSourceName = audioSourceKind.displayName
        sensitivity = settings.detectorSensitivity
        captionHoldSeconds = settings.captionHoldSeconds
        state.fontSize = settings.fontSize
        state.historyCount = settings.captionHistoryCount
        translator.preferredTargetID = settings.preferredTargetID
        languageMode = settings.languageMode
        if case .fixed(let id) = settings.languageMode,
           let language = LanguageTable.default.language(id: id) {
            currentLanguage = language
        } else {
            currentLanguage = .korean
        }
        syncLanguage()
    }

    /// 언어 관련 화면 상태는 한곳에서만 갱신한다. 번역 대상은 테이블이 정한다 —
    /// 언어팩 다운로드 시트도 이 쌍을 보고 뜬다.
    private func syncLanguage() {
        state.sourceLanguage = currentLanguage
        state.targetLanguage = LanguageTable.default.target(
            for: currentLanguage, preferredID: settings.preferredTargetID) ?? .english
        switch languageMode {
        case .auto: state.languageTitle = "자동 (실험)"
        case .fixed(let id): state.languageTitle = LanguageTable.default.language(id: id)?.displayName ?? id
        }
    }

    /// running과 버튼 상태는 controller의 상태 하나에서 함께 갱신한다.
    /// 시작 요청을 보냈다고 곧바로 "듣는 중"으로 바꾸지 않는다.
    private func apply(_ pipelineState: PipelineController.State) {
        switch pipelineState {
        case .stopped:
            running = false
            state.toggleTitle = "시작"
            state.status = "일시 정지"
        case .starting:
            running = true
            state.toggleTitle = "정지"
            state.status = "음성 엔진 시작 중…"
        case .listening:
            running = true
            state.toggleTitle = "정지"
            updateListeningStatus()
        case .stopping:
            state.toggleTitle = "정지 중…"
        case .failed(let message):
            running = false
            state.toggleTitle = "다시 시작"
            state.status = "시작 실패: \(message)"
        }
        state.isRunning = running
        state.canToggle = true
    }

    private func handle(_ event: PipelineEvent) {
        switch event.kind {
        case .installing(let fraction):
            let percent = max(0, min(100, Int(fraction * 100)))
            state.status = "음성 모델 설치 중 · \(percent)%"
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
        // 목록 규칙(추가 vs 갱신, 옛 줄 찾아가기, 트리밍)은 전부 CaptionState 에 있다.
        // 여기는 글루다 — 화면을 비우는 판단이 이 경로에 끼어들 자리가 없다.
        // nil 은 이미 밀려난 옛 발화의 갱신이라는 뜻이고, 그러면 번역도 걸지 않는다.
        guard let captionID = state.apply(event) else { return }
        translator.submit(event.transcript, from: event.sourceLanguage, captionID: captionID)
        // 말이 이어지는 동안에는 지우기 타이머를 계속 뒤로 민다.
        scheduleCaptionClear()

        if case .auto = languageMode, event.isFinal {
            proposeAutomaticLanguage(for: event.text)
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
        let width = settings.panelWidth ?? 560
        let size = NSSize(width: width, height: settings.panelHeight ?? 188)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless],
                        backing: .buffered, defer: false)
        // 발표·전체화면 위에도 자막이 보여야 한다.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        // SwiftUI 는 내용만 그린다. 창 자체는 AppKit 이 잡는다 —
        // SwiftUI Scene 으로는 .screenSaver borderless 오버레이를 만들 수 없다.
        let overlay = CaptionOverlay(
            state: state,
            onToggle: { [weak self] in self?.toggleListening() },
            onClear: { [weak self] in self?.clearCaptions() },
            onCycleLanguage: { [weak self] in self?.cycleLanguage() },
            onCycleAudioSource: { [weak self] in self?.cycleAudioSource() },
            onQuit: { [weak self] in self?.quitApp() },
            onHeight: { [weak self] height in self?.fitPanel(toContentHeight: height) })
        let hosting = NSHostingView(rootView: overlay)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting

        if let screen = NSScreen.main {
            let x = settings.panelOriginX ?? (screen.visibleFrame.midX - size.width / 2)
            let y = settings.panelOriginY ?? (screen.visibleFrame.minY + 54)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        NSApp.activate()
    }

    /// 자막이 쌓이면 창이 위로 자라야 한다. NSWindow 는 좌상단을 고정한 채 커지므로
    /// 높이만 바꾸면 자막이 화면 아래로 밀린다 — 좌하단(minY)을 고정해 위로 키운다.
    private func fitPanel(toContentHeight height: CGFloat) {
        guard let panel, height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        let frame = NSRect(x: panel.frame.minX, y: panel.frame.minY,
                           width: panel.frame.width, height: height)
        panel.setFrame(frame, display: true)
    }

    private func requestPermissionsAndStart() {
        // 완료 핸들러는 임의 스레드에서 불린다. UI 갱신은 메인 액터로 넘긴다.
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.state.status = "마이크 권한이 필요합니다"
                    self.state.canToggle = false
                    return
                }
                self.startListening()
            }
        }
    }

    private func toggleListening() {
        running ? stopListening() : startListening()
    }

    private func clearCaptions() {
        state.clear()
        invalidateCaptions()
    }

    /// 진행 중인 번역 작업과 clear 타이머를 취소한다.
    private func invalidateCaptions() {
        clearTask?.cancel()
        clearTask = nil
        translator.reset()
        // 장부만 비운다. 화면의 자막은 남긴다 — 정지했다고 읽던 줄을 뺏지 않는다.
        state.resetLedger()
    }

    private func quitApp() {
        stopListening()
        NSApp.terminate(nil)
    }

    /// 수동 한국어/영어 전환과 설정의 fixed ID가 같은 configuration 경로를 탄다.
    private func cycleLanguage() {
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
        if running {
            translator.reset() // 언어쌍이 바뀌므로 진행 중이던 번역·보정은 무효화한다.
            controller.requestReconfigure(configuration: currentConfiguration)
        }
    }

    /// 마이크/시스템 오디오 전환도 언어 전환과 같은 경로를 탄다 — `currentConfiguration`
    /// 스냅샷을 바꾸고 controller에 재구성을 요청한다. 소스 변경은 모듈 구성 자체가
    /// 달라지므로(PipelineController 참고) 항상 재시작이다.
    private func cycleAudioSource() {
        audioSourceKind = audioSourceKind == .microphone ? .systemAudio : .microphone
        state.audioSourceName = audioSourceKind.displayName
        if running {
            translator.reset()
            controller.requestReconfigure(configuration: currentConfiguration)
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
        state.status = "● 듣는 중 · \(mode)"
    }

    /// 자막을 지우는 건 **침묵**뿐이다. 발화가 바뀌었다는 이유로는 지우지 않는다.
    /// DispatchWorkItem 대신 Task 를 쓴다 — 메인 액터 격리를 그대로 물려받고 취소도 같다.
    private func scheduleCaptionClear() {
        clearTask?.cancel()
        let hold = captionHoldSeconds
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(hold))
            guard !Task.isCancelled, let self else { return }
            self.state.clear()
            self.translator.reset() // 유지 시간 만료 — 대기 중이던 번역도 무효화.
            self.clearTask = nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
