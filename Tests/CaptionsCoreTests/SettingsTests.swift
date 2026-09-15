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
    settings.panelOriginX = 120
    settings.panelOriginY = 64
    settings.preferredTargetID = "en-US"
    settings.panelWidth = 720
    settings.panelHeight = 240

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

@Test func 기본값은_LLM_보정이_꺼져_있다() {
    #expect(Settings.default.refinementEnabled == false)
}

@Test func 새_optional_필드가_없는_옛_JSON도_기존_값을_보존하며_읽힌다() {
    let defaults = freshDefaults("test.legacy")
    // preferredTargetID, panelWidth, panelHeight 가 없는 구버전 JSON을 손으로 만든다.
    let legacyJSON = """
    {
        "languageMode": { "fixed": { "_0": "ja-JP" } },
        "audioSource": "systemAudio",
        "fontSize": 24,
        "captionHoldSeconds": 6,
        "detectorSensitivity": "low",
        "refinementEnabled": true
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
    #expect(loaded.panelHeight == nil)
}
