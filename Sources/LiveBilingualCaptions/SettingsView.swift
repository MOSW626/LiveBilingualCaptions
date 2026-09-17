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

    @State private var apiKey = ""
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
                    Text("자동").tag("auto")
                    ForEach(table.languages) { language in
                        Text(language.displayName).tag(language.id)
                            .disabled(availability.disabledLanguageIDs.contains(language.id))
                    }
                }
                // 자동 모드는 문장을 보고 언어를 추측하지 않는다 — 한국어·영어 인식을
                // 동시에 돌려 신뢰도가 높은 쪽을 그때그때 채택한다. 정확하지만 연산은
                // 배로 든다.
                Text("자동 모드는 한국어·영어 인식을 동시에 돌려 신뢰도가 높은 쪽을 채택합니다. 연산을 두 배로 씁니다.")
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
                Toggle("자막 잠금(클릭 통과)", isOn: $settings.overlayLocked)
                Text("잠그면 자막 패널이 마우스를 통과시켜 그 아래 영상·창을 그대로 조작할 수 있습니다. 대신 패널을 옮기거나 크기를 바꿀 수 없으니, 해제는 메뉴바 '자막' 메뉴에서 하세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("기록") {
                Toggle("확정된 자막을 파일로 남기기", isOn: $settings.captionLogEnabled)
                Text("화면은 최근 \(settings.captionHistoryCount)줄만 보여줍니다. 켜두면 밀려난 줄이 원문·번역과 함께 문서 폴더의 세션 파일에 쌓여, 놓친 말을 나중에 다시 읽을 수 있습니다. 들리는 말이 디스크에 남는다는 뜻이기도 합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("로그 폴더 열기") {
                    let directory = CaptionLog.defaultDirectory
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(directory)
                }
            }
            Section("번역 보정") {
                Toggle("LLM 으로 확정 문장 다듬기", isOn: $settings.refinementEnabled)
                Text("켜면 확정된 문장과 직전 대화 맥락이 선택한 제공자(아래 피커) 서버로 전송되어 번역을 다듬습니다. 그 아래 칸에 해당 제공자의 API 키를 입력하세요. 끄면 모든 처리가 기기 안에서 끝납니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.refinementEnabled {
                    Picker("보정 제공자", selection: $settings.refinementProvider) {
                        ForEach(RefinementProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .onChange(of: settings.refinementProvider) { _, _ in loadStoredKey() }
                    SecureField(apiKeyFieldLabel, text: $apiKey)
                        .onSubmit { saveAPIKey() }
                    Button("키 저장", action: saveAPIKey)
                    if settings.refinementProvider == .openai {
                        TextField("OpenAI 모델", text: $settings.openAIModel)
                        Text("요청이 거부되면(모델을 찾을 수 없음 등) 여기 모델 이름을 바꿔보세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !keySaveStatus.isEmpty {
                        Text(keySaveStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    } else if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("\(apiKeyFieldLabel)가 없어 보정이 동작하지 않습니다")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("키는 Keychain 에 제공자별로 따로 저장됩니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { loadStoredKey() }
    }

    private var keychainAccount: String {
        settings.refinementProvider == .claude ? KeychainStore.apiKeyAccount : KeychainStore.openAIKeyAccount
    }

    private var apiKeyFieldLabel: String {
        settings.refinementProvider == .claude ? "Anthropic API 키" : "OpenAI API 키"
    }

    private func loadStoredKey() {
        apiKey = KeychainStore.read(account: keychainAccount) ?? ""
        keySaveStatus = ""
    }

    private func saveAPIKey() {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            keySaveStatus = "API 키를 입력하세요"
            return
        }
        guard KeychainStore.save(value, account: keychainAccount) else {
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
