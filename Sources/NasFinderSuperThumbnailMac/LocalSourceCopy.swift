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

    /// One bounded recovery for a transient byte-count discrepancy (e.g. WebDAV returning more/fewer bytes than the file size).
    /// Only when the copy was cancelled-free, error-free, the locked descriptor still has the SAME dev/inode/size as `expected`
    /// and the copied byte count differs from `fileSize`: the own partial copy is deleted and the SAME descriptor is copied once more
    /// from offset 0 (fresh hash, offset and progress). The second result is returned as is; the caller still requires an exact
    /// byte count and the unchanged identity checks. No trimming, padding or size acceptance happens here.
    static func copyRetryingSizeMismatch(
        sourceFD: Int32,
        to destURL: URL,
        fileSize: Int64,
        expected: LocalFileIdentity,
        inspect: (Int32) throws -> LocalFileIdentity = { try LocalFileIdentity.inspect(fd: $0) },
        chunkSize: Int = defaultChunkSize,
        hooks: Hooks = Hooks(),
        onProgress: (Double, String) -> Void
    ) throws -> (sha256: String, copiedBytes: Int64, retried: Bool) {
        let first = try copy(sourceFD: sourceFD, to: destURL, fileSize: fileSize, chunkSize: chunkSize, hooks: hooks, onProgress: onProgress)
        guard first.copiedBytes != fileSize else { return (first.sha256, first.copiedBytes, false) }
        try Task.checkCancellation()
        guard try inspect(sourceFD).isSameFile(as: expected) else { return (first.sha256, first.copiedBytes, false) }
        // Own workspace partial only (the copy is read-only 0400 and was created by this attempt); never touches the source.
        try withFileErrorPhase("원본 복사 크기 불일치 재시도 준비") {
            try FileManager.default.removeItem(at: destURL)
        }
        let second = try copy(sourceFD: sourceFD, to: destURL, fileSize: fileSize, chunkSize: chunkSize, hooks: hooks, onProgress: onProgress)
        return (second.sha256, second.copiedBytes, true)
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
        // The retry promise is a restart from zero: never assume the offset, require the actual result.
        let seekResult = lseek(dupSourceFD, 0, SEEK_SET)
        guard seekResult == 0 else {
            let err = seekResult < 0 ? errno : 0
            throw fileErrorAddingPhase(
                NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [NSLocalizedDescriptionKey: "원본 읽기 위치를 처음으로 되돌리지 못했습니다 (errno \(err), 결과 \(seekResult))"]),
                phase: "원본 복사 시작 위치 설정"
            )
        }

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
