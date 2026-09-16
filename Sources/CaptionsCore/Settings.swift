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

public struct Settings: Codable, Equatable, Sendable {
    public var languageMode: LanguageMode
    public var preferredTargetID: String?
    public var audioSource: AudioSourceKind
    public var fontSize: Double
    public var captionHoldSeconds: Double
    public var detectorSensitivity: DetectorSensitivity
    public var refinementEnabled: Bool
    /// 화면에 남겨둘 최근 발화 개수. 말이 끊이지 않는 화자에게 읽을 시간을 준다.
    public var captionHistoryCount: Int
    public var panelOriginX: Double?
    public var panelOriginY: Double?
    public var panelWidth: Double?
    public var panelHeight: Double?

    public static let storageKey = "settings.v1"
    public static let defaultCaptionHistoryCount = 3
    public static let captionHistoryCountRange = 1...10

    public static let `default` = Settings(
        languageMode: .auto,
        preferredTargetID: nil,
        audioSource: .microphone,
        fontSize: 20,
        captionHoldSeconds: 10,
        detectorSensitivity: .medium,
        refinementEnabled: false,      // 네트워크·비용이 드는 기능은 기본 꺼짐
        captionHistoryCount: defaultCaptionHistoryCount,
        panelOriginX: nil,
        panelOriginY: nil,
        panelWidth: nil,
        panelHeight: nil)

    public init(
        languageMode: LanguageMode,
        preferredTargetID: String?,
        audioSource: AudioSourceKind,
        fontSize: Double,
        captionHoldSeconds: Double,
        detectorSensitivity: DetectorSensitivity,
        refinementEnabled: Bool,
        captionHistoryCount: Int,
        panelOriginX: Double?,
        panelOriginY: Double?,
        panelWidth: Double?,
        panelHeight: Double?
    ) {
        self.languageMode = languageMode
        self.preferredTargetID = preferredTargetID
        self.audioSource = audioSource
        self.fontSize = fontSize
        self.captionHoldSeconds = captionHoldSeconds
        self.detectorSensitivity = detectorSensitivity
        self.refinementEnabled = refinementEnabled
        self.captionHistoryCount = captionHistoryCount
        self.panelOriginX = panelOriginX
        self.panelOriginY = panelOriginY
        self.panelWidth = panelWidth
        self.panelHeight = panelHeight
    }

    private enum CodingKeys: String, CodingKey {
        case languageMode, preferredTargetID, audioSource, fontSize, captionHoldSeconds
        case detectorSensitivity, refinementEnabled, captionHistoryCount
        case panelOriginX, panelOriginY, panelWidth, panelHeight
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
        let storedCount = try container.decodeIfPresent(Int.self, forKey: .captionHistoryCount)
            ?? Settings.defaultCaptionHistoryCount
        let range = Settings.captionHistoryCountRange
        captionHistoryCount = min(max(storedCount, range.lowerBound), range.upperBound)
        panelOriginX = try container.decodeIfPresent(Double.self, forKey: .panelOriginX)
        panelOriginY = try container.decodeIfPresent(Double.self, forKey: .panelOriginY)
        panelWidth = try container.decodeIfPresent(Double.self, forKey: .panelWidth)
        panelHeight = try container.decodeIfPresent(Double.self, forKey: .panelHeight)
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
