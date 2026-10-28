import CryptoKit
import Darwin
import Foundation

/// Copies the already locked source descriptor (via `dup`, never a re-open) into the private workspace while hashing.
/// Only EINTR on `read` is retried: at most `maxReadInterruptRetries` times, on the same descriptor at the same offset.
/// Every other errno fails at once, naming the phase, errno and copied offset. Nothing is written, hashed or counted for a
/// read that did not return bytes.
enum LocalSourceCopier {
    static let maxReadInterruptRetries = 3
    static let defaultChunkSize = 512 * 1024

    /// Injection seam; the defaults are the real syscalls.
    struct Hooks {
        var read: (Int32, UnsafeMutableRawPointer, Int) -> Int = { Darwin.read($0, $1, $2) }
        var write: (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    }

    static func copy(
        sourceFD: Int32,
        to destURL: URL,
        fileSize: Int64,
        chunkSize: Int = defaultChunkSize,
        hooks: Hooks = Hooks(),
        onProgress: (Double, String) -> Void
    ) throws -> (sha256: String, copiedBytes: Int64) {
        let dupSourceFD = dup(sourceFD)
        guard dupSourceFD >= 0 else {
            let err = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "원본 디스크립터 복제 실패 (errno \(err))"])
        }
        let sourceHandle = FileHandle(fileDescriptor: dupSourceFD, closeOnDealloc: true)
        defer { withExtendedLifetime(sourceHandle) {} } // the duplicate stays open (and is closed) with the copy
        _ = lseek(dupSourceFD, 0, SEEK_SET)

        let destFD = open(destURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destFD >= 0 else {
            let err = errno
            throw fileErrorAddingPhase(
                NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "복사 대상 파일 생성 실패 (errno \(err))"]),
                phase: "원본 복사 대상 생성"
            )
        }
        let destHandle = FileHandle(fileDescriptor: destFD, closeOnDealloc: true)
        defer { try? destHandle.close() }

        var hasher = SHA256()
        var copied: Int64 = 0
        var lastReportedPercent = -1
        var buffer = [UInt8](repeating: 0, count: max(1, chunkSize))
        onProgress(0, "다운로드 중")
        while true {
            try Task.checkCancellation()
            var retries = 0
            var count = 0
            while true {
                count = buffer.withUnsafeMutableBytes { hooks.read(dupSourceFD, $0.baseAddress!, $0.count) }
                if count >= 0 { break }
                let err = errno
                let phase = "원본 복사 읽기 (offset \(copied)/\(fileSize))"
                guard err == EINTR else {
                    throw fileErrorAddingPhase(
                        NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "원본 복사 읽기 실패 (errno \(err))"]),
                        phase: phase
                    )
                }
                if retries >= maxReadInterruptRetries {
                    throw fileErrorAddingPhase(
                        NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "원본 복사 읽기 실패 (errno \(err), \(maxReadInterruptRetries)회 재시도 후)"]),
                        phase: phase
                    )
                }
                retries += 1
                try Task.checkCancellation()
            }
            if count == 0 { break }

            let chunk = Data(buffer[0..<count])
            try withFileErrorPhase("원본 복사 쓰기 (offset \(copied)/\(fileSize))") { try hooks.write(destHandle, chunk) }
            hasher.update(data: chunk)
            copied += Int64(count)
            if fileSize > 0 {
                // Cap at 0.99 until the copy size and source identity are verified.
                let fraction = min(0.99, Double(copied) / Double(fileSize))
                let percent = Int(fraction * 100)
                if percent != lastReportedPercent {
                    lastReportedPercent = percent
                    onProgress(fraction, "다운로드 중")
                }
            }
        }
        try withFileErrorPhase("원본 복사 동기화 (offset \(copied)/\(fileSize))") { try destHandle.synchronize() }
        try withFileErrorPhase("원본 복사본 권한 설정") {
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destURL.path)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), copied)
    }
}
