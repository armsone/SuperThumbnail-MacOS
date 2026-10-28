import AppKit
import Foundation

// MARK: - Local Conversion History Record

struct LocalConversionHistoryRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let folderID: UUID
    let sourceURL: URL
    let relativePath: String
    let relativeComponents: [String]
    let fileSize: Int64
    let device: Int64
    let inode: UInt64
    let mtimeNanoseconds: Int64
    let stageName: String // "completed", "failed", "skipped", "cancelled"
    let stageDetail: String?
    let statusMessage: String
    let date: Date

    /// Only terminal items are persisted; a non-terminal stage is never silently turned into "completed".
    init?(item: LocalConversionItem) {
        self.id = item.id
        self.folderID = item.folderID
        self.sourceURL = item.sourceURL
        self.relativePath = item.relativePath
        self.relativeComponents = item.relativeComponents
        self.fileSize = item.fileSize
        self.device = Int64(item.identity.device)
        self.inode = UInt64(item.identity.inode)
        self.mtimeNanoseconds = item.identity.mtimeNanoseconds
        switch item.stage {
        case .completed:
            self.stageName = "completed"
            self.stageDetail = nil
        case .failed(let msg):
            self.stageName = "failed"
            self.stageDetail = msg
        case .skipped(let reason):
            self.stageName = "skipped"
            self.stageDetail = reason
        case .cancelled:
            self.stageName = "cancelled"
            self.stageDetail = nil
        case .pending, .preparing, .copyingSource, .converting, .verifying, .staging, .publishing:
            return nil
        }
        self.statusMessage = item.statusMessage
        self.date = item.addedDate
    }

    /// nil for an unknown stage name or out-of-range integers (the record is rejected, never guessed).
    func toItem() -> LocalConversionItem? {
        let stage: LocalConversionStage
        switch stageName {
        case "completed":
            stage = .completed
        case "failed":
            stage = .failed(stageDetail ?? statusMessage)
        case "skipped":
            stage = .skipped(stageDetail ?? statusMessage)
        case "cancelled":
            stage = .cancelled
        default:
            return nil
        }

        guard fileSize >= 0, mtimeNanoseconds >= 0,
              let dev = dev_t(exactly: device),
              let mtimeSec = time_t(exactly: mtimeNanoseconds / 1_000_000_000) else {
            return nil
        }

        let identity = LocalFileIdentity(
            device: dev,
            inode: ino_t(inode),
            size: fileSize,
            mtime: mtimeSec,
            mtime_nsec: Int(mtimeNanoseconds % 1_000_000_000)
        )

        return LocalConversionItem(
            id: id,
            folderID: folderID,
            sourceURL: sourceURL,
            relativePath: relativePath,
            relativeComponents: relativeComponents,
            fileSize: fileSize,
            identity: identity,
            stage: stage,
            statusMessage: statusMessage,
            addedDate: date
        )
    }
}

/// One undecodable element must not discard the rest of the file.
private struct LossyHistoryRecord: Decodable {
    let record: LocalConversionHistoryRecord?

    init(from decoder: Decoder) throws {
        record = try? LocalConversionHistoryRecord(from: decoder)
    }
}

struct LocalHistoryLoadOutcome: Sendable {
    var items: [LocalConversionItem]
    var notice: String?
}

// MARK: - Local Conversion History Store

/// Serial, ordered file I/O off the main thread. Holds the authoritative record set so that a save made before
/// the old file was loaded can never overwrite it, and refuses to write after an unreadable file until it was preserved.
final class LocalConversionHistoryStore: @unchecked Sendable {
    static let shared = LocalConversionHistoryStore()

    private static let subDirectoryName = "NasFinderSuperThumbnailMac"
    private static let historyFileName = "conversion_history_v1.json"
    private static let maxCompletedRetention = 500

    private let queue = DispatchQueue(label: "com.superthumbnail.local-conversion-history", qos: .utility)
    // Everything below is confined to `queue`.
    private var records: [UUID: LocalConversionHistoryRecord] = [:]
    private var loaded = false
    private var writesBlockedReason: String?

    private init() {}

    private var storageURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.subDirectoryName, isDirectory: true)
    }

    private var historyFileURL: URL? {
        storageURL?.appendingPathComponent(Self.historyFileName)
    }

    // MARK: Public API (completions run on the store queue)

    func load(completion: @escaping @Sendable (LocalHistoryLoadOutcome) -> Void) {
        queue.async {
            let notice = self.ensureLoaded()
            completion(LocalHistoryLoadOutcome(items: self.sortedItems(), notice: notice))
        }
    }

    /// Persists the given terminal items; completion receives nil on success or a readable failure message.
    func upsert(_ items: [LocalConversionItem], completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            _ = self.ensureLoaded()
            for item in items {
                if let record = LocalConversionHistoryRecord(item: item) {
                    self.records[record.id] = record
                }
            }
            completion(self.writeAll())
        }
    }

    /// Clears only the history file and records. Media files and shared work markers are never touched.
    func clear(completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            _ = self.ensureLoaded()
            self.records.removeAll()
            if let reason = self.writesBlockedReason {
                completion(reason)
                return
            }
            guard let fileURL = self.historyFileURL else {
                completion("변환 기록 저장 위치를 찾지 못했습니다.")
                return
            }
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                completion(nil)
            } catch {
                completion("변환 기록 파일을 지우지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Queue-confined helpers

    private func sortedItems() -> [LocalConversionItem] {
        records.values.compactMap { $0.toItem() }.sorted { $0.addedDate > $1.addedDate }
    }

    /// Loads once. Returns a notice only the first time something needs the user's attention.
    private func ensureLoaded() -> String? {
        guard !loaded else { return nil }
        loaded = true

        guard let fileURL = historyFileURL else {
            writesBlockedReason = "변환 기록 저장 위치를 찾지 못해 기록을 저장하지 않습니다."
            return writesBlockedReason
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return nil }
            if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT) { return nil }
            writesBlockedReason = "변환 기록 파일을 읽지 못해 기존 기록을 보호하려고 저장을 멈췄습니다: \(error.localizedDescription)"
            return writesBlockedReason
        }

        let decoded: [LossyHistoryRecord]
        do {
            decoded = try JSONDecoder().decode([LossyHistoryRecord].self, from: data)
        } catch {
            let backupURL = Self.sideFileURL(for: fileURL, tag: "corrupt")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
                return "변환 기록 파일이 손상되어 \(backupURL.lastPathComponent)(으)로 보관하고 새로 시작합니다."
            } catch {
                writesBlockedReason = "변환 기록 파일이 손상되었고 보관에도 실패해 기존 파일을 보호하려고 저장을 멈췄습니다: \(error.localizedDescription)"
                return writesBlockedReason
            }
        }

        var rejected = 0
        for entry in decoded {
            if let record = entry.record, record.toItem() != nil {
                records[record.id] = record
            } else {
                rejected += 1
            }
        }

        if rejected > 0 {
            let backupURL = Self.sideFileURL(for: fileURL, tag: "rejected")
            do {
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
                return "변환 기록 \(rejected)개를 읽지 못해 제외했습니다. 원본 파일은 \(backupURL.lastPathComponent)에 보관했습니다."
            } catch {
                writesBlockedReason = "변환 기록 \(rejected)개를 읽지 못했고 원본 보관에도 실패해 기존 파일을 보호하려고 저장을 멈췄습니다."
                return writesBlockedReason
            }
        }
        return nil
    }

    private static func sideFileURL(for fileURL: URL, tag: String) -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let base = fileURL.deletingPathExtension().lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent("\(base).\(tag)-\(stamp)-\(UUID().uuidString.prefix(8)).json")
    }

    /// Keeps every failed / skipped / cancelled record; only old completed records are capped.
    private func writeAll() -> String? {
        if let reason = writesBlockedReason { return reason }
        guard let dirURL = storageURL, let fileURL = historyFileURL else {
            return "변환 기록 저장 위치를 찾지 못했습니다."
        }

        let completed = records.values.filter { $0.stageName == "completed" }.sorted { $0.date > $1.date }
        if completed.count > Self.maxCompletedRetention {
            for record in completed.dropFirst(Self.maxCompletedRetention) {
                records.removeValue(forKey: record.id)
            }
        }

        let ordered = records.values.sorted { $0.date > $1.date }
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ordered)
            try data.write(to: fileURL, options: .atomic)
            return nil
        } catch {
            return "변환 기록을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }
}
