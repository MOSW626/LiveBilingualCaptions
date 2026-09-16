/// CaptionsCore — UI 의존이 없는 자막 로직. 테스트 대상은 전부 이 모듈에 있다.
///
/// 모듈과 이름이 같은 타입을 두면 `ModuleName.Type` qualification이 막힌다(타입이 모듈
/// 이름을 가려버린다) — 실행 타깃이 SwiftUI의 `Settings`(Scene)와 겹치는 `CaptionsCore.Settings`를
/// `CaptionsCore.Settings`로 명시해야 하는데 그 경로가 막히면 안 되므로 이름을 다르게 둔다.
public enum CaptionsCoreModule {
    public static let moduleName = "CaptionsCore"
}
