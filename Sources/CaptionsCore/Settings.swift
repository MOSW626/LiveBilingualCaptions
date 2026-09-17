import Foundation

public enum AudioSourceKind: String, Codable, Sendable, CaseIterable {
    case microphone, systemAudio

    public var displayName: String {
        switch self {
        case .microphone: "마이크"
        case .systemAudio: "시스템 오디오"
        }
    }
}

public enum LanguageMode: Equatable, Codable, Sendable {
    case auto
    case fixed(String)      // CaptionLanguage.id
}

public enum DetectorSensitivity: String, Codable, Sendable, CaseIterable {
    case low, medium, high

    public var displayName: String {
        switch self {
        case .low: "낮음"
        case .medium: "보통"
        case .high: "높음"
        }
    }
}

public enum RefinementProvider: String, Codable, Sendable, CaseIterable {
    case claude, openai

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openai: "OpenAI"
        }
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var languageMode: LanguageMode
    public var preferredTargetID: String?
    public var audioSource: AudioSourceKind
    public var fontSize: Double
    public var captionHoldSeconds: Double
    public var detectorSensitivity: DetectorSensitivity
    public var refinementEnabled: Bool
    /// 보정을 어느 제공자에게 맡길지. 제공자마다 Keychain 계정이 따로 있다.
    public var refinementProvider: RefinementProvider
    /// OpenAI 보정에 쓸 모델 이름. 검증된 고정 ID가 없어 사용자가 직접 바꿀 수 있게 둔다.
    public var openAIModel: String
    /// 화면에 남겨둘 최근 발화 개수. 말이 끊이지 않는 화자에게 읽을 시간을 준다.
    public var captionHistoryCount: Int
    /// 확정 자막을 파일로도 남길지. 화면은 최근 몇 줄만 보여주므로, 놓친 말을 나중에
    /// 다시 읽으려면 파일이 유일한 경로다.
    public var captionLogEnabled: Bool
    /// 켜면 패널이 마우스를 완전히 통과시킨다 — 영상 위에 올려두고 그 아래를 조작할 수
    /// 있다. 대신 드래그·크기조절도 막히므로 해제는 메뉴바에서 한다.
    public var overlayLocked: Bool
    public var panelOriginX: Double?
    public var panelOriginY: Double?
    public var panelWidth: Double?

    public static let storageKey = "settings.v1"
    public static let defaultCaptionHistoryCount = 3
    public static let captionHistoryCountRange = 1...10
    public static let defaultOpenAIModel = OpenAIRefiner.defaultModel

    public static let `default` = Settings(
        languageMode: .auto,
        preferredTargetID: nil,
        audioSource: .microphone,
        fontSize: 20,
        captionHoldSeconds: 10,
        detectorSensitivity: .medium,
        refinementEnabled: false,      // 네트워크·비용이 드는 기능은 기본 꺼짐
        refinementProvider: .claude,
        openAIModel: defaultOpenAIModel,
        captionHistoryCount: defaultCaptionHistoryCount,
        captionLogEnabled: true,
        overlayLocked: false,
        panelOriginX: nil,
        panelOriginY: nil,
        panelWidth: nil)

    public init(
        languageMode: LanguageMode,
        preferredTargetID: String?,
        audioSource: AudioSourceKind,
        fontSize: Double,
        captionHoldSeconds: Double,
        detectorSensitivity: DetectorSensitivity,
        refinementEnabled: Bool,
        refinementProvider: RefinementProvider,
        openAIModel: String,
        captionHistoryCount: Int,
        captionLogEnabled: Bool = true,
        overlayLocked: Bool = false,
        panelOriginX: Double?,
        panelOriginY: Double?,
        panelWidth: Double?
    ) {
        self.languageMode = languageMode
        self.preferredTargetID = preferredTargetID
        self.audioSource = audioSource
        self.fontSize = fontSize
        self.captionHoldSeconds = captionHoldSeconds
        self.detectorSensitivity = detectorSensitivity
        self.refinementEnabled = refinementEnabled
        self.refinementProvider = refinementProvider
        self.openAIModel = openAIModel
        self.captionHistoryCount = captionHistoryCount
        self.captionLogEnabled = captionLogEnabled
        self.overlayLocked = overlayLocked
        self.panelOriginX = panelOriginX
        self.panelOriginY = panelOriginY
        self.panelWidth = panelWidth
    }

    private enum CodingKeys: String, CodingKey {
        case languageMode, preferredTargetID, audioSource, fontSize, captionHoldSeconds
        case detectorSensitivity, refinementEnabled, refinementProvider, openAIModel
        case captionHistoryCount, captionLogEnabled, overlayLocked
        case panelOriginX, panelOriginY, panelWidth
    }

    /// `captionHistoryCount`는 옛 저장값엔 없을 수 있는 non-optional 필드다 — 없으면
    /// 기본값으로, 있어도 범위(1...10) 밖이면 clamp 한다. 새 필드 하나가 옛 설정을
    /// 통째로 날리거나 시작을 막지 않도록.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        languageMode = try container.decode(LanguageMode.self, forKey: .languageMode)
        preferredTargetID = try container.decodeIfPresent(String.self, forKey: .preferredTargetID)
        audioSource = try container.decode(AudioSourceKind.self, forKey: .audioSource)
        fontSize = try container.decode(Double.self, forKey: .fontSize)
        captionHoldSeconds = try container.decode(Double.self, forKey: .captionHoldSeconds)
        detectorSensitivity = try container.decode(DetectorSensitivity.self, forKey: .detectorSensitivity)
        refinementEnabled = try container.decode(Bool.self, forKey: .refinementEnabled)
        refinementProvider = try container.decodeIfPresent(RefinementProvider.self, forKey: .refinementProvider)
            ?? .claude
        openAIModel = try container.decodeIfPresent(String.self, forKey: .openAIModel)
            ?? Settings.defaultOpenAIModel
        let storedCount = try container.decodeIfPresent(Int.self, forKey: .captionHistoryCount)
            ?? Settings.defaultCaptionHistoryCount
        let range = Settings.captionHistoryCountRange
        captionHistoryCount = min(max(storedCount, range.lowerBound), range.upperBound)
        captionLogEnabled = try container.decodeIfPresent(Bool.self, forKey: .captionLogEnabled) ?? true
        overlayLocked = try container.decodeIfPresent(Bool.self, forKey: .overlayLocked) ?? false
        panelOriginX = try container.decodeIfPresent(Double.self, forKey: .panelOriginX)
        panelOriginY = try container.decodeIfPresent(Double.self, forKey: .panelOriginY)
        panelWidth = try container.decodeIfPresent(Double.self, forKey: .panelWidth)
        // panelHeight: 더 이상 저장·노출하지 않는다. CodingKeys에 없으므로 옛 JSON에 이
        // 키가 남아 있어도(추가 키는 무시된다) 디코드가 실패하지 않는다.
    }

    /// 저장된 값이 없거나 형식이 깨졌으면 기본값으로 돌아간다.
    /// 설정 하나 때문에 앱이 못 뜨는 상황을 만들지 않는다.
    public static func load(from defaults: UserDefaults) -> Settings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .default }
        return decoded
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
