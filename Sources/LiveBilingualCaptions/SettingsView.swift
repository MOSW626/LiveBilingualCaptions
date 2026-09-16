import SwiftUI
import CaptionsCore

/// 설정 창 전체. 모든 컨트롤이 같은 `Binding<Settings>`를 거친다 — 대입 시점마다
/// AppDelegate의 `apply(_:)`가 이전 값과 비교해 저장·반영·필요할 때만 재구성을 한다.
/// 그래서 여기엔 onChange가 따로 없다: 값을 세팅하는 것 자체가 적용이다.
struct SettingsView: View {
    @Binding var settings: CaptionsCore.Settings
    var table: LanguageTable
    var availability: LanguageAvailabilityState
    /// 키 저장 성공 시 AppDelegate 가 번역기의 보정기를 다시 연결하도록 알린다.
    /// 토글을 켠 뒤 처음 키를 저장하는 순간에도(재토글·재실행 없이) 반영되려면 필요하다.
    var onAPIKeySaved: () -> Void

    @State private var apiKey = KeychainStore.read(account: KeychainStore.apiKeyAccount) ?? ""
    @State private var keySaveStatus = ""

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
                // 원문 자막이 늦게 뜬다는 불만은 대개 음성 감지(VAD)가 "이건 말이다"라고
                // 판단하는 데 걸리는 시간 때문이다. 무엇을 눌러야 할지 짐작하게 두지 않고
                // 증상과 조치를 직접 연결한다.
                Text("자막이 늦거나 주변이 시끄러우면 '낮음'을 먼저 시도하세요. 애매한 소리도 말로 더 빨리 인정해 반응이 빨라지지만, 오작동(엉뚱하게 자막이 뜨는 것)도 늘 수 있습니다. '높음'은 확실한 소리만 말로 인정해 오작동은 줄지만 반응이 늦어질 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Section("번역 보정") {
                Toggle("Claude 로 확정 문장 다듬기", isOn: $settings.refinementEnabled)
                Text("켜면 확정된 문장만 인터넷으로 전송됩니다. 끄면 모든 처리가 기기 안에서 끝납니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.refinementEnabled {
                    SecureField("Anthropic API 키", text: $apiKey)
                        .onSubmit { saveAPIKey() }
                    Button("키 저장", action: saveAPIKey)
                    if !keySaveStatus.isEmpty {
                        Text(keySaveStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("키는 Keychain 에 저장됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    private func saveAPIKey() {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            keySaveStatus = "API 키를 입력하세요"
            return
        }
        guard KeychainStore.save(value, account: KeychainStore.apiKeyAccount) else {
            keySaveStatus = "키를 저장하지 못했습니다"
            return
        }
        keySaveStatus = "키를 저장했습니다"
        onAPIKeySaved() // 저장에 성공했을 때만 보정기를 갱신한다
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
