import Testing
@testable import CaptionsCore

// 설정 창·오버레이 버튼이 공유하는 하나뿐인 적용 경로(`applySettingsChange`)를 검증한다.
// 실제 PipelineController 대신 가짜를 써서 "재구성을 몇 번 요청했는지"만 본다.

@MainActor
private final class FakeReconfigureController: ReconfigureRequesting {
    private(set) var requestedConfigurations: [PipelineConfiguration] = []
    func requestReconfigure(configuration: PipelineConfiguration) {
        requestedConfigurations.append(configuration)
    }
}

private let config = PipelineConfiguration(source: .microphone, language: .korean, sensitivity: .medium)

@Test @MainActor func 값이_같으면_아무_필드도_변경으로_보지_않는다() {
    let controller = FakeReconfigureController()
    let settings = Settings.default
    let result = applySettingsChange(old: settings, new: settings, running: true,
                                     configuration: config, controller: controller)
    #expect(result == SettingsApplyResult(captureChanged: false, pairChanged: false,
                                          holdChanged: false, didReconfigure: false))
    #expect(controller.requestedConfigurations.isEmpty)
}

@Test @MainActor func 오디오_소스가_바뀌면_실행_중일_때_재구성을_한_번_한다() {
    let controller = FakeReconfigureController()
    var new = Settings.default
    new.audioSource = .systemAudio
    let result = applySettingsChange(old: .default, new: new, running: true,
                                     configuration: config, controller: controller)
    #expect(result.captureChanged)
    #expect(result.didReconfigure)
    #expect(controller.requestedConfigurations.count == 1)
    #expect(controller.requestedConfigurations[0] == config)
}

@Test @MainActor func 언어_모드가_바뀌면_실행_중일_때_재구성을_한_번_한다() {
    let controller = FakeReconfigureController()
    var new = Settings.default
    new.languageMode = .fixed("en-US")
    let result = applySettingsChange(old: .default, new: new, running: true,
                                     configuration: config, controller: controller)
    #expect(result.captureChanged)
    #expect(result.didReconfigure)
    #expect(controller.requestedConfigurations.count == 1)
}

@Test @MainActor func 감지_민감도가_바뀌면_실행_중일_때_재구성을_한_번_한다() {
    let controller = FakeReconfigureController()
    var new = Settings.default
    new.detectorSensitivity = .high
    let result = applySettingsChange(old: .default, new: new, running: true,
                                     configuration: config, controller: controller)
    #expect(result.captureChanged)
    #expect(result.didReconfigure)
    #expect(controller.requestedConfigurations.count == 1)
}

@Test @MainActor func 폰트_크기만_바뀌면_재구성하지_않는다() {
    let controller = FakeReconfigureController()
    var new = Settings.default
    new.fontSize = 32
    let result = applySettingsChange(old: .default, new: new, running: true,
                                     configuration: config, controller: controller)
    #expect(!result.captureChanged)
    #expect(!result.didReconfigure)
    #expect(controller.requestedConfigurations.isEmpty)
}

@Test @MainActor func 정지_중에는_캡처_변경이어도_컨트롤러를_건드리지_않는다() {
    // 다음 시작이 최신 configuration을 쓰므로, 멈춰 있는 파이프라인을 깨울 이유가 없다.
    let controller = FakeReconfigureController()
    var new = Settings.default
    new.audioSource = .systemAudio
    let result = applySettingsChange(old: .default, new: new, running: false,
                                     configuration: config, controller: controller)
    #expect(result.captureChanged)
    #expect(!result.didReconfigure)
    #expect(controller.requestedConfigurations.isEmpty)
}

@Test @MainActor func 기본_번역_대상만_바뀌면_pairChanged만_켜진다() {
    let controller = FakeReconfigureController()
    var new = Settings.default
    new.preferredTargetID = "en-US"
    let result = applySettingsChange(old: .default, new: new, running: true,
                                     configuration: config, controller: controller)
    #expect(!result.captureChanged)
    #expect(result.pairChanged)
    #expect(!result.didReconfigure)
    #expect(controller.requestedConfigurations.isEmpty)
}

@Test @MainActor func 유지_시간만_바뀌면_holdChanged만_켜진다() {
    let controller = FakeReconfigureController()
    var new = Settings.default
    new.captionHoldSeconds = 5
    let result = applySettingsChange(old: .default, new: new, running: true,
                                     configuration: config, controller: controller)
    #expect(!result.captureChanged)
    #expect(!result.pairChanged)
    #expect(result.holdChanged)
    #expect(controller.requestedConfigurations.isEmpty)
}

@Test @MainActor func 언어_모드_변경은_pairChanged도_함께_켠다() {
    // 번역 방향이 원문 언어에 좌우되므로, 언어 모드 변경도 언어쌍 재조회 대상이다.
    let controller = FakeReconfigureController()
    var new = Settings.default
    new.languageMode = .fixed("en-US")
    let result = applySettingsChange(old: .default, new: new, running: false,
                                     configuration: config, controller: controller)
    #expect(result.captureChanged)
    #expect(result.pairChanged)
}
