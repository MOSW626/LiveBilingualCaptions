import SwiftUI
import CaptionsCore

/// 설정 창 전체. 모든 컨트롤이 같은 `Binding<Settings>`를 거친다 — 대입 시점마다
/// AppDelegate의 `apply(_:)`가 이전 값과 비교해 저장·반영·필요할 때만 재구성을 한다.
/// 그래서 여기엔 onChange가 따로 없다: 값을 세팅하는 것 자체가 적용이다.
struct SettingsView: View {
    @Binding var settings: CaptionsCore.Settings
    var table: LanguageTable
    var availability: LanguageAvailabilityState

    var body: some View {
        Form {
            Section("오디오") {
                Picker("입력", selection: $settings.audioSource) {
                    ForEach(AudioSourceKind.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("음성 감지 민감도", selection: $settings.detectorSensitivity) {
                    ForEach(DetectorSensitivity.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
            Section("언어") {
                Picker("인식 언어", selection: languageSelection) {
                    Text("자동 (실험)").tag("auto")
                    ForEach(table.languages) { language in
                        Text(language.displayName).tag(language.id)
                            .disabled(availability.disabledLanguageIDs.contains(language.id))
                    }
                }
                // 자동 감지는 장식이 아니라 실제로 신뢰도가 낮다 — 오인식된 한두 단어로
                // 언어를 잘못 판단할 수 있다. 기본값이 한국어 고정인 이유이기도 하다.
                Text("자동 모드는 잘못 인식된 문장으로 언어를 판단할 수 있습니다. 정확한 전환은 언어를 직접 선택하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if table.languages.count >= 3 {
                    Picker("기본 번역 대상", selection: $settings.preferredTargetID) {
                        Text("첫 번째 다른 언어").tag(nil as String?)
                        ForEach(table.languages) { language in
                            Text(language.displayName).tag(Optional(language.id))
                                .disabled(availability.disabledTargetIDs.contains(language.id))
                        }
                    }
                }
                if !availability.downloadHintPairIDs.isEmpty {
                    Text("일부 언어쌍은 번역을 시작할 때 언어팩 다운로드가 필요합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("자막") {
                Slider(value: $settings.fontSize, in: 14...40, step: 1) {
                    Text("글자 크기 \(Int(settings.fontSize))pt")
                }
                Slider(value: $settings.captionHoldSeconds, in: 3...30, step: 1) {
                    Text("유지 시간 \(Int(settings.captionHoldSeconds))초")
                }
                Stepper(value: $settings.captionHistoryCount, in: Settings.captionHistoryCountRange) {
                    Text("표시 개수 \(settings.captionHistoryCount)줄")
                }
            }
            // "번역 보정" 섹션은 Task 10이 추가한다. updateRefiner()가 아직 없으므로
            // 여기서 토글을 노출하면 동작하지 않는 스위치가 되고 apply()가 컴파일되지 않는다.
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: {
                switch settings.languageMode {
                case .auto: "auto"
                case .fixed(let id): id
                }
            },
            set: { settings.languageMode = $0 == "auto" ? .auto : .fixed($0) })
    }
}
