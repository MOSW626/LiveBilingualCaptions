import Testing
import Foundation
@testable import CaptionsCore

private func freshDefaults(_ name: String) -> UserDefaults {
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Test func 저장하고_불러오면_같은_값() {
    let defaults = freshDefaults("test.roundtrip")
    var settings = Settings.default
    settings.languageMode = .fixed("en-US")
    settings.audioSource = .systemAudio
    settings.fontSize = 28
    settings.captionHoldSeconds = 4.5
    settings.detectorSensitivity = .high
    settings.refinementEnabled = true
    settings.captionHistoryCount = 5
    settings.panelOriginX = 120
    settings.panelOriginY = 64
    settings.preferredTargetID = "en-US"
    settings.panelWidth = 720

    settings.save(to: defaults)
    #expect(Settings.load(from: defaults) == settings)
}

@Test func 저장된_값이_없으면_기본값() {
    let defaults = freshDefaults("test.empty")
    #expect(Settings.load(from: defaults) == Settings.default)
}

@Test func 손상된_값이_있으면_기본값으로_복구() {
    let defaults = freshDefaults("test.corrupt")
    defaults.set("이건 JSON 이 아니다", forKey: Settings.storageKey)
    #expect(Settings.load(from: defaults) == Settings.default)
}

@Test func 디코드에_실패하는_Data도_기본값으로_복구() {
    // 위 테스트는 String 값을 넣어 `data(forKey:)` 가 nil을 돌려주는 분기만 지난다.
    // 여기서는 실제 Data를 넣되 Settings로 디코드할 수 없는 내용으로 만들어
    // `try? JSONDecoder().decode(...)` 가 nil을 돌려주는 분기를 지나게 한다.
    let defaults = freshDefaults("test.undecodable")
    defaults.set(Data("{ this is not valid json".utf8), forKey: Settings.storageKey)
    #expect(Settings.load(from: defaults) == Settings.default)
}

@Test func 기본값은_LLM_보정이_꺼져_있다() {
    #expect(Settings.default.refinementEnabled == false)
}

@Test func 새_optional_필드가_없는_옛_JSON도_기존_값을_보존하며_읽힌다() {
    let defaults = freshDefaults("test.legacy")
    // preferredTargetID, panelWidth 뿐 아니라 captionHistoryCount(non-optional로 나중에
    // 추가된 필드)도 없는 구버전 JSON을 손으로 만든다. 새 필드 하나가 옛 설정을 통째로
    // 날려서는 안 된다. panelHeight는 반대로, 더 이상 쓰지 않는 필드가 남아 있는 옛
    // JSON — CodingKeys에서 빠졌다고 디코드가 깨지면 안 된다.
    let legacyJSON = """
    {
        "languageMode": { "fixed": { "_0": "ja-JP" } },
        "audioSource": "systemAudio",
        "fontSize": 24,
        "captionHoldSeconds": 6,
        "detectorSensitivity": "low",
        "refinementEnabled": true,
        "panelHeight": 240
    }
    """
    defaults.set(Data(legacyJSON.utf8), forKey: Settings.storageKey)

    let loaded = Settings.load(from: defaults)
    #expect(loaded.languageMode == .fixed("ja-JP"))
    #expect(loaded.audioSource == .systemAudio)
    #expect(loaded.fontSize == 24)
    #expect(loaded.captionHoldSeconds == 6)
    #expect(loaded.detectorSensitivity == .low)
    #expect(loaded.refinementEnabled == true)
    #expect(loaded.preferredTargetID == nil)
    #expect(loaded.panelWidth == nil)
    #expect(loaded.captionHistoryCount == Settings.defaultCaptionHistoryCount)
}
