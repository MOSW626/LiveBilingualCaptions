import Foundation

/// `PipelineController`가 구현하는 최소 인터페이스. 설정 적용 로직을 실제 파이프라인
/// 없이(가짜로) 테스트하기 위한 경계다.
@MainActor
public protocol ReconfigureRequesting: AnyObject {
    func requestReconfigure(configuration: PipelineConfiguration)
}

extension PipelineController: ReconfigureRequesting {}

/// 설정 적용 한 번의 판단 결과. 어떤 종류의 변경이었는지와 실제로 재구성을 요청했는지를
/// 함께 담아, 호출자가 후속 작업(캡션 무효화, 언어쌍 재조회, 타이머 재설정)을 결정한다.
public struct SettingsApplyResult: Sendable, Equatable {
    /// 오디오 소스·언어 모드·감지 민감도 중 하나라도 바뀌었다 — 파이프라인 구성 자체가 달라진다.
    public let captureChanged: Bool
    /// 번역 방향에 영향을 주는 변경(기본 대상·언어 모드) — 언어쌍 가용성을 다시 조회해야 한다.
    public let pairChanged: Bool
    /// 자막 유지 시간이 바뀌었다 — 진행 중인 clear 타이머를 다시 계산해야 한다.
    public let holdChanged: Bool
    /// `captureChanged && running`일 때만 true. 정지 중에는 다음 시작 설정만 갱신하고
    /// 컨트롤러를 건드리지 않는다.
    public let didReconfigure: Bool
}

/// 설정 창·오버레이 버튼 어느 쪽에서 온 변경이든 지나는 **하나뿐인** 적용 경로.
///
/// 글꼴 크기처럼 캡처와 무관한 필드만 바뀌었다면 `captureChanged`가 false라 컨트롤러를
/// 전혀 건드리지 않는다 — 재구성 1회조차 발생하지 않는다. 실행 중이 아니면(`running == false`)
/// `captureChanged`가 true여도 재구성을 요청하지 않는다: 다음 `requestStart`가 어차피 최신
/// `configuration`을 사용하므로, 멈춰 있는 파이프라인을 임의로 깨울 이유가 없다.
@MainActor
public func applySettingsChange(
    old: Settings, new: Settings, running: Bool,
    configuration: PipelineConfiguration, controller: any ReconfigureRequesting
) -> SettingsApplyResult {
    let captureChanged = old.audioSource != new.audioSource
        || old.languageMode != new.languageMode
        || old.detectorSensitivity != new.detectorSensitivity
    let pairChanged = old.preferredTargetID != new.preferredTargetID
        || old.languageMode != new.languageMode
    let holdChanged = old.captionHoldSeconds != new.captionHoldSeconds

    var didReconfigure = false
    if captureChanged && running {
        controller.requestReconfigure(configuration: configuration)
        didReconfigure = true
    }
    return SettingsApplyResult(captureChanged: captureChanged, pairChanged: pairChanged,
                               holdChanged: holdChanged, didReconfigure: didReconfigure)
}
