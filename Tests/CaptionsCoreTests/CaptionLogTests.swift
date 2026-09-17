import Foundation
import Testing
@testable import CaptionsCore

@MainActor
@Suite("자막 로그")
struct CaptionLogTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptionLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func fixedClock(_ iso: String) -> () -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = f.date(from: iso)!
        return { date }
    }

    @Test("원문과 번역을 시각과 함께 덧붙인다")
    func appendsBilingualLines() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = fixedClock("2026-09-17 14:03:21")
        let log = CaptionLog(directory: dir, now: clock)

        log.append(CaptionEntry(id: UUID(), original: "안녕하세요", translated: "Hello", isFinal: true),
                   spokenAt: clock())
        log.append(CaptionEntry(id: UUID(), original: "반갑습니다", translated: "Nice to meet you", isFinal: true),
                   spokenAt: clock())
        log.close()

        let url = try #require(log.fileURL)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == """
        [14:03:21] 안녕하세요
                   Hello
        [14:03:21] 반갑습니다
                   Nice to meet you

        """)
        #expect(url.lastPathComponent == "2026-09-17 14-03.txt")
    }

    @Test("번역이 없으면 원문 줄만 쓴다")
    func writesSourceOnlyWhenUntranslated() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = CaptionLog(directory: dir, now: fixedClock("2026-09-17 09:00:00"))

        log.append(CaptionEntry(id: UUID(), original: "번역 못 받은 줄", translated: "", isFinal: true),
                   spokenAt: fixedClock("2026-09-17 09:00:05")())
        log.close()

        let text = try String(contentsOf: #require(log.fileURL), encoding: .utf8)
        #expect(text == "[09:00:05] 번역 못 받은 줄\n")
    }

    @Test("아무 줄도 안 오면 파일을 만들지 않는다")
    func createsNoFileUntilFirstLine() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = CaptionLog(directory: dir, now: fixedClock("2026-09-17 09:00:00"))

        log.append(CaptionEntry(id: UUID(), original: "   ", translated: "", isFinal: true),
                   spokenAt: Date())
        log.close()

        #expect(log.fileURL == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("밀려난 줄이 되돌아와 다시 밀려나도 한 번만 쓴다")
    func skipsRepeatOfIdenticalLine() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = CaptionLog(directory: dir, now: fixedClock("2026-09-17 18:10:00"))
        let id = UUID()
        let at = fixedClock("2026-09-17 18:10:14")()

        log.append(CaptionEntry(id: id, original: "같은 문장", translated: "same", isFinal: true), spokenAt: at)
        log.append(CaptionEntry(id: id, original: "같은 문장", translated: "same", isFinal: true), spokenAt: at)
        // 내용이 자란 뒤늦은 final 은 갱신이므로 다시 쓴다.
        log.append(CaptionEntry(id: id, original: "같은 문장 더 있음", translated: "same, more", isFinal: true), spokenAt: at)
        log.close()

        let text = try String(contentsOf: #require(log.fileURL), encoding: .utf8)
        #expect(text == """
        [18:10:14] 같은 문장
                   same
        [18:10:14] 같은 문장 더 있음
                   same, more

        """)
    }

    @Test("쓸 수 없는 경로여도 던지지 않는다")
    func survivesUnwritableDirectory() {
        let log = CaptionLog(directory: URL(fileURLWithPath: "/dev/null/nope"),
                             now: fixedClock("2026-09-17 09:00:00"))
        log.append(CaptionEntry(id: UUID(), original: "한 줄", translated: "", isFinal: true),
                   spokenAt: Date())
        log.close()
        #expect(log.fileURL == nil)
    }
}

@MainActor
@Suite("자막 줄 퇴출 알림")
struct CaptionEvictionTests {
    @Test("밀려난 확정 줄만, 처음 뜬 시각과 함께 넘어온다")
    func reportsEvictedFinalLines() {
        let state = CaptionState()
        state.historyCount = 1
        let born = Date(timeIntervalSince1970: 1_000)
        state.now = { born }
        var seen: [(CaptionEntry, Date)] = []
        state.onEvict = { seen.append(($0, $1)) }

        let first = UUID(), second = UUID()
        state.upsert(id: first, original: "첫 줄", isFinal: true)
        state.setTranslation("first line", for: first)
        state.upsert(id: second, original: "둘째 줄", isFinal: true)

        #expect(seen.count == 1)
        #expect(seen.first?.0.original == "첫 줄")
        #expect(seen.first?.0.translated == "first line")
        #expect(seen.first?.1 == born)
    }

    @Test("진행 중인 줄은 넘기지 않는다")
    func skipsUnfinishedLines() {
        let state = CaptionState()
        state.historyCount = 1
        var seen: [CaptionEntry] = []
        state.onEvict = { entry, _ in seen.append(entry) }

        state.upsert(id: UUID(), original: "아직 말하는 중", isFinal: false)
        state.upsert(id: UUID(), original: "다음 줄", isFinal: true)

        #expect(seen.isEmpty)
    }

    @Test("비우기도 남은 줄을 넘긴다")
    func clearReportsRemainingLines() {
        let state = CaptionState()
        var seen: [CaptionEntry] = []
        state.onEvict = { entry, _ in seen.append(entry) }

        state.upsert(id: UUID(), original: "남은 줄", isFinal: true)
        state.clear()

        #expect(seen.map(\.original) == ["남은 줄"])
    }
}
