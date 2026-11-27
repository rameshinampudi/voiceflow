import Combine
import Foundation

public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var appName: String?
    public var mode: DictationMode
    public var rawText: String
    public var finalText: String
    public var audioSeconds: Double
    public var aiUsed: Bool

    public init(
        id: UUID = UUID(), date: Date = Date(), appName: String?, mode: DictationMode,
        rawText: String, finalText: String, audioSeconds: Double, aiUsed: Bool
    ) {
        self.id = id
        self.date = date
        self.appName = appName
        self.mode = mode
        self.rawText = rawText
        self.finalText = finalText
        self.audioSeconds = audioSeconds
        self.aiUsed = aiUsed
    }

    public var wordCount: Int { finalText.split(whereSeparator: \.isWhitespace).count }
}

public struct HistoryStats: Equatable, Sendable {
    public var totalWords: Int
    public var wordsToday: Int
    public var averageWPM: Int
    public var sessions: Int
}

/// Recent dictations, kept in `history.json` so a failed paste is never lost.
public final class HistoryStore: ObservableObject {
    @Published public private(set) var entries: [HistoryEntry] = []
    public let fileURL: URL?
    public let maxEntries: Int

    public init(fileURL: URL?, maxEntries: Int = 1000) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
        load()
    }

    public func add(_ entry: HistoryEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Newest first, optionally filtered by text in the final text, original transcript or app name.
    public func search(_ query: String, limit: Int? = nil) -> [HistoryEntry] {
        let needle = query.trimmed
        var result = entries.reversed().filter { entry in
            needle.isEmpty
                || entry.finalText.localizedCaseInsensitiveContains(needle)
                || entry.rawText.localizedCaseInsensitiveContains(needle)
                || (entry.appName?.localizedCaseInsensitiveContains(needle) ?? false)
        }
        if let limit, result.count > limit { result = Array(result.prefix(limit)) }
        return result
    }

    public func stats(now: Date = Date(), calendar: Calendar = .current) -> HistoryStats {
        let total = entries.reduce(0) { $0 + $1.wordCount }
        let today = entries
            .filter { calendar.isDate($0.date, inSameDayAs: now) }
            .reduce(0) { $0 + $1.wordCount }
        let seconds = entries.reduce(0.0) { $0 + $1.audioSeconds }
        let wpm = seconds > 0 ? Int((Double(total) / (seconds / 60)).rounded()) : 0
        return HistoryStats(totalWords: total, wordsToday: today, averageWPM: wpm, sessions: entries.count)
    }

    private func load() {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("VoiceFlow: could not save history: \(error)")
        }
    }
}
