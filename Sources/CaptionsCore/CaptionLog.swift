import Foundation

/// 확정 자막을 세션 파일에 덧붙인다.
///
/// 화면은 최근 몇 줄만 보여주기 때문에, 놓친 말을 나중에 다시 읽을 길이 이것뿐이다.
/// 줄이 화면에서 밀려나는 순간(`CaptionState.onEvict`)에 쓰므로 원문도 번역도 최종이고,
/// 밀려나는 순서가 곧 말한 순서라 정렬이 저절로 맞는다.
///
/// **로그 실패는 절대 자막을 멈추지 않는다.** 디렉터리를 못 만들든 디스크가 꽉 찼든
/// 조용히 포기하고, 이후 호출은 시도조차 하지 않는다.
@MainActor
public final class CaptionLog {
    /// 첫 줄이 올 때까지 파일을 만들지 않는다 — 켜고 아무 말도 안 한 세션이 빈 파일을
    /// 남기지 않게. 그래서 파일명의 시각은 "앱을 켠 때"가 아니라 "첫 자막"이다.
    private var handle: FileHandle?
    private var failed = false
    private let directory: URL
    private let now: () -> Date

    public private(set) var fileURL: URL?

    public init(directory: URL = CaptionLog.defaultDirectory, now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
    }

    public static var defaultDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("LiveBilingualCaptions", isDirectory: true)
    }

    /// 한 줄을 덧붙인다. `spokenAt` 은 그 줄이 **화면에 처음 뜬** 시각이다 — 밀려난
    /// 시각으로 찍으면 화면에 머문 시간만큼(최대 10초 남짓) 전부 뒤로 밀린다.
    public func append(_ entry: CaptionEntry, spokenAt: Date) {
        let original = entry.original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return }
        var line = "[\(Self.stamp.string(from: spokenAt))] \(original)\n"
        let translated = entry.translated.trimmingCharacters(in: .whitespacesAndNewlines)
        if !translated.isEmpty { line += "           \(translated)\n" }
        write(line)
    }

    /// 열려 있으면 닫는다. 종료 경로에서 부른다.
    public func close() {
        try? handle?.close()
        handle = nil
    }

    private func write(_ line: String) {
        guard !failed, let data = line.data(using: .utf8) else { return }
        guard let handle = openedHandle() else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            failed = true
            close()
        }
    }

    private func openedHandle() -> FileHandle? {
        if let handle { return handle }
        let fm = FileManager.default
        let url = directory.appendingPathComponent("\(Self.fileStamp.string(from: now())).txt")
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil) else { failed = true; return nil }
            }
            let opened = try FileHandle(forWritingTo: url)
            handle = opened
            fileURL = url
            return opened
        } catch {
            failed = true
            return nil
        }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()
}
