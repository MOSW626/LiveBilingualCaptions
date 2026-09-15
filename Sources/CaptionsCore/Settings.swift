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
    public var panelOriginX: Double?
    public var panelOriginY: Double?
    public var panelWidth: Double?
    public var panelHeight: Double?

    public static let storageKey = "settings.v1"

    public static let `default` = Settings(
        languageMode: .fixed("ko-KR"),
        preferredTargetID: nil,
        audioSource: .microphone,
        fontSize: 20,
        captionHoldSeconds: 10,
        detectorSensitivity: .medium,
        refinementEnabled: false,      // 네트워크·비용이 드는 기능은 기본 꺼짐
        panelOriginX: nil,
        panelOriginY: nil,
        panelWidth: nil,
        panelHeight: nil)

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
