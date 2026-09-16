import AppKit
import AVFoundation
import Observation
import SwiftUI
import CaptionsCore

/// Binding 하나로 설정 창과 AppDelegate가 같은 값을 본다. 대입 경로는 `AppDelegate.apply(_:)`
/// 하나뿐이다 — 이 프로퍼티를 직접 바꾸지 않는다.
@Observable
@MainActor
final class SettingsStore {
    var value = Settings.load(from: .standard)
}

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
    private let settingsStore = SettingsStore()
    private let availability = LanguageAvailabilityState()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    /// 리사이즈 핸들 드래그 시작 시점의 패널 폭. 드래그 중엔 여기 누적 이동량을 더해
    /// 목표 폭을 구한다(델타를 계속 더하면 반올림 오차가 쌓인다). 드래그가 끝나면 nil로
    /// 돌아가 다음 드래그가 그때의 실제 폭에서 다시 시작한다.
    private var resizeStartWidth: CGFloat?
    private var running = false
    private var clearTask: Task<Void, Never>?
    /// 자막은 지연에 민감하다 — 가장 빠른 Haiku 계열을 쓴다. 날짜 접미사를 붙이지 않는다.
    private let refinerModel = "claude-haiku-4-5"
    /// 마지막으로 자막이 갱신된 시각. 유지 시간 설정이 바뀌었을 때 "얼마나 지났는지"를
    /// 계산하는 기준이다. 지울 자막이 없으면(타이머가 없으면) nil이다.
    private var lastCaptionUpdate: Date?
    /// 자동 모드의 최초(추정) 언어는 한국어, 고정 모드는 저장한 ID를 쓴다. 자동 모드가
    /// 듣는 중에는 실제 채택 언어를 전사 이벤트(`event.sourceLanguage`)가 갱신한다 —
    /// `SpeechPipeline`이 두 언어를 동시에 인식해 신뢰도로 고른 값이다(스펙 §2).
    private var currentLanguage: CaptionLanguage = .korean {
        didSet { syncLanguage() }
    }

    private var languageMode: LanguageMode { settingsStore.value.languageMode }

    /// 설정에서 만든 소스·언어·민감도의 스냅샷. 모든 시작/재구성이 이 경로를 지난다.
    /// 자동 모드에서는 `secondaryLanguage`에 나머지 한 언어를 실어, 파이프라인이 두 벌을
    /// 동시에 돌리게 한다(한국어/영어 두 언어만 다루므로 고정 쌍이다).
    private var currentConfiguration: PipelineConfiguration {
        let secondary: CaptionLanguage?
        if case .auto = languageMode {
            secondary = currentLanguage == .korean ? .english : .korean
        } else {
            secondary = nil
        }
        return PipelineConfiguration(source: settingsStore.value.audioSource, language: currentLanguage,
                                      sensitivity: settingsStore.value.detectorSensitivity,
                                      secondaryLanguage: secondary)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyStoredSettings()
        updateRefiner()
        buildWindow()
        buildStatusItem()
        bindController()
        requestPermissionsAndStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
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
        let settings = settingsStore.value
        state.fontSize = settings.fontSize
        state.historyCount = settings.captionHistoryCount
        state.audioSourceName = settings.audioSource.displayName
        state.segmentCap = CaptionSegmenter.recommendedCap(
            panelWidth: settings.panelWidth ?? PanelFrame.defaultWidth, fontSize: settings.fontSize)
        translator.preferredTargetID = settings.preferredTargetID
        currentLanguage = resolveCurrentLanguage(for: settings.languageMode) // didSet이 syncLanguage()를 부른다
        refreshLanguagePairAvailability()
    }

    /// languageMode 에서 파생되는 인식 언어. 자동 모드의 시작(추정) 언어는 항상 한국어다 —
    /// 실제로는 두 언어를 동시에 듣기 시작하고, 첫 발화가 확정되면 신뢰도가 이 값을 갈아친다.
    private func resolveCurrentLanguage(for mode: LanguageMode) -> CaptionLanguage {
        switch mode {
        case .auto: .korean
        case .fixed(let id): LanguageTable.default.language(id: id) ?? .korean
        }
    }

    /// 언어 관련 화면 상태는 한곳에서만 갱신한다. 번역 대상은 테이블이 정한다 —
    /// 언어팩 다운로드 시트도 이 쌍을 보고 뜬다.
    private func syncLanguage() {
        state.sourceLanguage = currentLanguage
        state.targetLanguage = LanguageTable.default.target(
            for: currentLanguage, preferredID: settingsStore.value.preferredTargetID) ?? .english
        switch languageMode {
        case .auto: state.languageTitle = "자동"
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

    /// 설정 창·오버레이 버튼 어느 쪽에서 온 변경이든 지나는 **하나뿐인** 적용 경로.
    ///
    /// 마이크가 아닌 다른 소스로의 변경은 곧바로 `performApply`로 간다. **마이크로**
    /// 바뀌는 변경만 여기서 권한을 먼저 본다(FIX 1) — 거부 상태면 조용히 재구성을
    /// 밀어붙이지 않고 메시지를 띄운 채 돌아가고, 아직 물어본 적이 없으면 여기서 물어본
    /// 뒤 승인된 시점에만 실제로 적용한다. 승인 전까지는 `settingsStore`도 화면 라벨도
    /// 건드리지 않는다 — 그래야 실패해도 "마이크"라고 표시된 채 실제로는 이전 소스가
    /// 도는 불일치가 생기지 않는다.
    @discardableResult
    private func apply(_ new: CaptionsCore.Settings) -> Bool {
        guard new.audioSource == .microphone, settingsStore.value.audioSource != .microphone else {
            return performApply(new)
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return performApply(new)
        case .denied, .restricted:
            state.status = "마이크 권한이 필요합니다"
            state.canToggle = false
            return false
        default: // .notDetermined 및 앞으로 추가될 케이스
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    guard granted else {
                        self.state.status = "마이크 권한이 필요합니다"
                        self.state.canToggle = false
                        return
                    }
                    self.performApply(new)
                }
            }
            return true // 설정 자체는 유효한 요청이다 — 실제 반영은 권한 확인 뒤.
        }
    }

    /// 판단(무엇이 바뀌었는지, 재구성이 필요한지)은 `applySettingsChange`(CaptionsCore)가
    /// 순수하게 하고, 여기서는 그 결과를 받아 저장·화면 갱신·후속 작업만 한다.
    @discardableResult
    private func performApply(_ new: CaptionsCore.Settings) -> Bool {
        let old = settingsStore.value
        guard old != new else { return false }

        // hot swap 판정에 쓸 "전"의 값. 아래에서 currentLanguage·controller 상태가
        // 둘 다 바뀌므로 손대기 전에 찍어 둔다.
        let oldLanguage = currentLanguage
        let wasListening = controller.state == .listening

        if new.languageMode != old.languageMode {
            currentLanguage = resolveCurrentLanguage(for: new.languageMode)
        }
        settingsStore.value = new
        new.save(to: .standard)

        state.fontSize = new.fontSize
        state.historyCount = new.captionHistoryCount
        state.audioSourceName = new.audioSource.displayName
        // 안전망 상한은 폭·글자 크기가 실제로 바뀔 때만 다시 잰다(§ 일반 원칙: 실시간
        // 스레드는 물론 문장마다도 재계산하지 않는다) — CTLine 실측 비용을 여기서만 쓴다.
        if old.panelWidth != new.panelWidth || old.fontSize != new.fontSize {
            state.segmentCap = CaptionSegmenter.recommendedCap(
                panelWidth: new.panelWidth ?? PanelFrame.defaultWidth, fontSize: new.fontSize)
        }
        translator.preferredTargetID = new.preferredTargetID
        syncLanguage() // preferredTargetID만 바뀌어도 대상 언어가 달라질 수 있다
        if old.refinementEnabled != new.refinementEnabled { updateRefiner() }

        let result = applySettingsChange(old: old, new: new, running: running,
                                         configuration: currentConfiguration, controller: controller)

        // 말하는 도중의 언어 hot swap(SpeechPipeline.switchLanguage)은 같은 Run과
        // 그 ledger를 그대로 쓴다 — nextID가 이어진다. 여기서 장부(resetLedger)를 비우면
        // 그사이 도착하는 "구제된 final"이 방금 지운 장부에서 자기 줄을 못 찾아 새 UUID를
        // 받고, 옛 줄은 번역도 못 받은 채 화면에 남아 문장이 두 번 보인다(FIX 2).
        // 오디오 소스·민감도 변경이나, 듣고 있지 않을 때의 언어 변경은 실제로 새 Run으로
        // 재시작하므로(nextID가 1부터 다시 시작) 그때는 장부를 비워야 옛 ID와 충돌하지 않는다.
        //
        // 이 판정은 설정값만 보고 동기적으로 내린다 — SpeechPipeline.switchLanguage가
        // 런타임에 실패할 수 있다는 걸(지원하지 않는 locale, 호환 안 되는 오디오 포맷)
        // 미리 알 방법이 없다. 실패하면 PipelineController.drain()이 조용히 stop 후
        // 새 Run으로 재시작하고, 그 Run의 utteranceID는 1부터 다시 시작한다 — 이 판정이
        // "hot swap"이라고 잘못 믿고 장부를 살려 둔 채로. 하지만 그래도 안전하다:
        // CaptionState.captionIDs는 이제 utteranceID 단독이 아니라 (runID, utteranceID)
        // 쌍으로 키가 잡혀 있어서, 옛 Run이 남긴 항목이 새 Run의 같은 번호와 부딪히지
        // 않는다. 즉 이 판정의 정확성이 더 이상 정답성의 전제조건이 아니다 — 맞으면
        // 불필요한 리셋을 피하고 중복 줄(FIX 2)을 막아 줄 뿐이다. 그렇다고 "이제 필요
        // 없다"며 run 스코프를 걷어내지 말 것 — 이 판정이 여전히 진짜로 하는 일이다.
        let isHotLanguageSwap = old.audioSource == new.audioSource
            && old.detectorSensitivity == new.detectorSensitivity
            && oldLanguage != currentLanguage
            && wasListening
        if result.captureChanged || result.pairChanged {
            invalidateCaptions(resetLedger: !isHotLanguageSwap)
        }
        if result.pairChanged {
            refreshLanguagePairAvailability()
        }
        if result.holdChanged {
            rescheduleCaptionClear()
        }
        return result.didReconfigure
    }

    /// 보정 토글·키 저장 성공 시에만 부른다. 폰트 크기 같은 무관한 변경에는 부르지 않는다 —
    /// `Translator.refiner`의 didSet이 진행 중인 보정 작업을 매번 취소하기 때문이다.
    private func updateRefiner() {
        guard settingsStore.value.refinementEnabled,
              let key = KeychainStore.read(account: KeychainStore.apiKeyAccount),
              !key.isEmpty else {
            translator.refiner = nil
            return
        }
        translator.refiner = ClaudeRefiner(apiKey: key, model: refinerModel)
    }

    /// 음성 locale 지원 여부와 번역의 방향별 상태를 조회해 설정 창의 비활성/다운로드 안내를
    /// 갱신한다. 세대 관리는 `LanguageAvailabilityState` 안에서 한다.
    private func refreshLanguagePairAvailability() {
        let table = LanguageTable.default
        let source = currentLanguage
        let preferredID = settingsStore.value.preferredTargetID
        Task { [weak self] in
            await self?.availability.refresh(
                source: source, table: table, preferredTargetID: preferredID,
                packStatus: { await Translator.packStatus(from: $0, to: $1) })
        }
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
            show(transcript, runID: event.runID)
        case .failed:
            break // 상태 콜백이 메시지를 이미 보여준다
        }
    }

    private func show(_ event: TranscriptEvent, runID: Int) {
        // 자동 모드에서는 SpeechPipeline이 두 언어를 동시에 인식해 신뢰도로 고른 언어를
        // 이벤트에 이미 찍어 보낸다(스펙 §2) — 여기서는 그 값을 그대로 따라가 화면
        // 상태만 갱신한다. 텍스트를 보고 언어를 다시 추측하지 않는다(§2 배경: 문자열
        // 분류는 엉뚱한 전사기가 만든 글자를 못 구해낸다). requestReconfigure도 부르지
        // 않는다 — 인식 자체는 이미 두 벌이 돌고 있어서 재시작이 필요 없다.
        if case .auto = languageMode, currentLanguage != event.sourceLanguage {
            currentLanguage = event.sourceLanguage
            refreshLanguagePairAvailability()
            if running { updateListeningStatus() }
        }

        // 목록 규칙(추가 vs 갱신, 옛 줄 찾아가기, 트리밍, 문장 쪼개기)은 전부
        // CaptionState 에 있다. 여기는 글루다 — 화면을 비우는 판단이 이 경로에 끼어들
        // 자리가 없다. 빈 배열은 이미 밀려난 옛 발화의 갱신이라는 뜻이고, 그러면
        // 번역도 걸지 않는다. runID를 같이 넘긴다 — CaptionState의 장부는 (runID,
        // utteranceID, segmentIndex) 세 쌍으로 키가 잡혀 있어서, 언어 hot swap이
        // 런타임에 실패해 새 Run이 조용히 열려도(그래서 utteranceID가 1부터
        // 되풀이돼도) 옛 Run의 매핑과 절대 부딪히지 않는다.
        //
        // 이벤트 하나가 문장 여러 개로 쪼개질 수 있다 — 조각마다 자기 UUID와 자기
        // transcript로 따로 번역을 건다(스펙 §1). 원문 전체가 아니라 조각의 텍스트만
        // 넘기므로 번역도 문장 단위로 붙는다.
        let updates = state.apply(event, runID: runID)
        guard !updates.isEmpty else { return }
        for update in updates {
            translator.submit(update.transcript, from: event.sourceLanguage, captionID: update.id)
        }
        // 말이 이어지는 동안에는 지우기 타이머를 계속 뒤로 민다.
        scheduleCaptionClear()
    }

    /// `LSUIElement`라 Dock 아이콘이 없다 — 설정은 메뉴바에서 연다.
    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "자막"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "설정…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = SettingsView(
            settings: Binding(get: { self.settingsStore.value }, set: { self.apply($0) }),
            table: .default,
            availability: availability,
            onAPIKeySaved: { [weak self] in self?.updateRefiner() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Live Bilingual Captions 설정"
        window.isReleasedWhenClosed = false // 닫아도 재사용한다 — 매번 새로 만들지 않는다
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        settingsWindow = window
    }

    private func buildWindow() {
        let stored = settingsStore.value
        let screen = screenContaining(x: stored.panelOriginX, y: stored.panelOriginY) ?? NSScreen.main
        let frame: CGRect = if let screen {
            PanelFrame.restoredFrame(storedOriginX: stored.panelOriginX, storedOriginY: stored.panelOriginY,
                                     storedWidth: stored.panelWidth, visibleFrame: screen.visibleFrame)
        } else {
            CGRect(x: 0, y: 0, width: PanelFrame.defaultWidth, height: PanelFrame.minHeight)
        }

        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .resizable],
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
            onHeight: { [weak self] height in self?.fitPanel(toContentHeight: height) },
            onResizeChanged: { [weak self] translationX in self?.resizePanel(translationX: translationX) },
            onResizeEnded: { [weak self] in self?.resizeStartWidth = nil })
        let hosting = NSHostingView(rootView: overlay)
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        panel.contentView = hosting

        panel.orderFrontRegardless()
        NSApp.activate()
        // 복원이 끝난 뒤에 구독한다 — 초기 setFrame이 방금 읽은 저장값을 덮어쓰지 않게.
        observePanelGeometry()
    }

    /// 저장된 원점을 담고 있는 화면을 찾는다. 값이 없거나 유효하지 않거나, 그 화면이
    /// 더 이상 연결돼 있지 않으면 nil — 호출자가 기본 화면으로 대체한다.
    private func screenContaining(x: Double?, y: Double?) -> NSScreen? {
        guard let x, let y, x.isFinite, y.isFinite else { return nil }
        let point = CGPoint(x: x, y: y)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func observePanelGeometry() {
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.persistPanelGeometry() }
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main, using: handler)
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: panel, queue: .main, using: handler)
    }

    /// 위치와 너비만 저장한다 — 높이는 자동 성장이 정하므로(Task 7) 저장 대상이 아니다.
    /// 이 경로로도 `apply(_:)`를 거치므로 값이 실제로 안 바뀌었으면(예: 높이만 변한 리사이즈)
    /// 아무 일도 하지 않는다.
    private func persistPanelGeometry() {
        guard let panel else { return }
        var updated = settingsStore.value
        updated.panelOriginX = panel.frame.origin.x
        updated.panelOriginY = panel.frame.origin.y
        updated.panelWidth = panel.frame.width
        apply(updated)
    }

    /// 자막이 쌓이면 창이 위로 자라야 한다. `PanelFrame.clamped`가 화면 밖으로 넘치지
    /// 않게 막는다 — 화면 위쪽에 붙은 패널이 무한정 자라 사라지는 일을 막는다.
    private func fitPanel(toContentHeight height: CGFloat) {
        guard let panel, height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let clampedFrame = PanelFrame.clamped(
            origin: panel.frame.origin,
            size: CGSize(width: panel.frame.width, height: height),
            visibleFrame: visibleFrame)
        panel.setFrame(clampedFrame, display: true)
    }

    /// 리사이즈 핸들 드래그를 패널 폭에 반영한다. 높이·origin은 건드리지 않는다 — 폭만
    /// 사용자가 바꾸는 값이고, 높이는 여전히 내용이 정한다(Task 7의 자동 성장). 클램프는
    /// `PanelFrame.clamped`가 하는 그대로다(최소 폭 = `PanelFrame.minWidth`로 버튼 행이
    /// 항상 들어가고, 최대 폭 = 현재 화면 `visibleFrame`을 넘지 않는다) — 리사이즈 전용
    /// 클램프를 새로 만들지 않는다.
    ///
    /// 이 경로는 patch를 직접 저장하지 않는다: `panel.setFrame`이 `NSWindow.
    /// didResizeNotification`을 발생시키고, 이미 구독 중인 `observePanelGeometry`가
    /// `persistPanelGeometry()` → `apply(_:)`로 흘려보낸다 — 창 이동(배경 드래그)이
    /// 저장되는 경로와 완전히 같다. 그래서 폭 변경도 다른 설정과 똑같이 **하나뿐인**
    /// 적용 경로를 탄다.
    private func resizePanel(translationX: CGFloat) {
        guard let panel else { return }
        let base = resizeStartWidth ?? panel.frame.width
        resizeStartWidth = base
        let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let clampedFrame = PanelFrame.clamped(
            origin: panel.frame.origin,
            size: CGSize(width: base + translationX, height: panel.frame.height),
            visibleFrame: visibleFrame)
        panel.setFrame(clampedFrame, display: true)
    }

    /// 마이크는 `.microphone` 소스일 때만 필요하다. 시스템 오디오는 화면 기록 권한으로
    /// 따로 게이트되고(`SystemAudioSource`), 마이크 TCC와는 무관하다 — 저장된 소스가
    /// 시스템 오디오인 사용자가 마이크를 거부했다고 앱 전체가 영영 멈추면 안 된다(FIX 1).
    private func requestPermissionsAndStart() {
        guard settingsStore.value.audioSource == .microphone else {
            startListening()
            return
        }
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
    ///
    /// `resetLedger`가 false면 발화 ID 장부는 남긴다 — 말하는 도중의 언어 hot swap처럼
    /// 같은 Run이 이어질 때 쓴다(FIX 2). 장부를 비우면 그사이 도착하는 "구제된 final"이
    /// 자기 줄을 못 찾아 새 줄로 중복 표시된다.
    private func invalidateCaptions(resetLedger: Bool = true) {
        clearTask?.cancel()
        clearTask = nil
        lastCaptionUpdate = nil
        translator.reset()
        if resetLedger {
            // 장부만 비운다. 화면의 자막은 남긴다 — 정지했다고 읽던 줄을 뺏지 않는다.
            state.resetLedger()
        }
    }

    @objc private func quitApp() {
        stopListening()
        NSApp.terminate(nil)
    }

    /// 수동 한국어/영어 전환과 설정의 fixed ID가 같은 configuration 경로를 탄다 —
    /// 둘 다 `apply(_ new: Settings)` 하나를 거친다.
    private func cycleLanguage() {
        var new = settingsStore.value
        switch languageMode {
        case .auto:
            new.languageMode = .fixed(CaptionLanguage.korean.id)
        case .fixed(let id) where id == CaptionLanguage.korean.id:
            new.languageMode = .fixed(CaptionLanguage.english.id)
        case .fixed:
            new.languageMode = .auto
        }
        apply(new)
    }

    /// 마이크/시스템 오디오 전환도 언어 전환과 같은 경로를 탄다.
    private func cycleAudioSource() {
        var new = settingsStore.value
        new.audioSource = new.audioSource == .microphone ? .systemAudio : .microphone
        apply(new)
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
        case .auto: mode = "자동 · \(currentLanguage.displayName)"
        case .fixed: mode = currentLanguage.displayName
        }
        state.status = "● 듣는 중 · \(mode)"
    }

    /// 자막을 지우는 건 **침묵**뿐이다. 발화가 바뀌었다는 이유로는 지우지 않는다.
    /// DispatchWorkItem 대신 Task 를 쓴다 — 메인 액터 격리를 그대로 물려받고 취소도 같다.
    private func scheduleCaptionClear() {
        lastCaptionUpdate = Date()
        scheduleClear(after: settingsStore.value.captionHoldSeconds)
    }

    private func scheduleClear(after seconds: Double) {
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.state.clear()
            self.translator.reset() // 유지 시간 만료 — 대기 중이던 번역도 무효화.
            self.clearTask = nil
            self.lastCaptionUpdate = nil
        }
    }

    /// 유지 시간 설정이 바뀌면 마지막 자막 갱신 시각을 기준으로 남은 시간만 다시 기다린다.
    /// 이미 만료됐어야 하면(예: 10초→3초로 줄였는데 이미 5초 지남) 즉시 지운다.
    private func rescheduleCaptionClear() {
        guard let lastCaptionUpdate else { return } // 지울 자막이 없으면 할 일이 없다
        let elapsed = Date().timeIntervalSince(lastCaptionUpdate)
        let remaining = settingsStore.value.captionHoldSeconds - elapsed
        if remaining <= 0 {
            clearTask?.cancel()
            clearTask = nil
            self.lastCaptionUpdate = nil
            state.clear()
            translator.reset()
        } else {
            scheduleClear(after: remaining)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
