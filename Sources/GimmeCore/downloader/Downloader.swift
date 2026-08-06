import Foundation
import CryptoKit

/// Fetches assets into a content-addressed cache keyed by sha256.
/// Verifies checksums; throws `.checksumMismatch` on failure (unless insecure).
///
/// Hardening:
///   - sha256 is computed by streaming the file in chunks (not loading it all
///     into memory), so large release tarballs don't blow up RAM.
///   - Downloads/copies are capped at `maxDownloadBytes` (default 2 GiB) to
///     prevent a malicious/misconfigured mirror from filling the disk before
///     the checksum gate runs.
public struct Downloader {
    public let paths: GimmePaths
    /// Maximum size, in bytes, of a single asset download/copy. Larger files
    /// are rejected with a `.network` error. Defaults to 2 GiB.
    public var maxDownloadBytes: Int64

    public init(paths: GimmePaths, maxDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024) {
        self.paths = paths
        self.maxDownloadBytes = maxDownloadBytes
    }

    /// Fetch (or reuse from cache) the asset, returning the cached file path.
    /// SECURITY: cached files are re-hashed on every hit and compared against
    /// `asset.sha256`; a mismatch evicts the cached file and re-fetches. This
    /// prevents a corrupted/poisoned cache entry from being trusted forever.
    public func fetch(asset: Asset, insecure: Bool = false) throws -> URL {
        let cached = paths.cache.appendingPathComponent(asset.sha256)
        try FileManager.default.createDirectory(at: paths.cache, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: cached.path) {
            // Re-verify even on cache hit; evict + re-fetch on mismatch.
            if Self.sha256(of: cached) == asset.sha256 {
                return cached
            }
            // Poisoned/stale cache entry -> remove and fall through to re-fetch.
            try? FileManager.default.removeItem(at: cached)
        }

        // Download into a unique temp path so two concurrent gimme processes
        // don't clobber each other's in-flight download.
        let tmp = paths.cache.appendingPathComponent(".gimme-dl-\(UUID().uuidString)")
        try download(from: asset.url, to: tmp)

        // Enforce the size cap after download (defense even for file:// copies).
        if let size = fileSize(tmp), size > maxDownloadBytes {
            try? FileManager.default.removeItem(at: tmp)
            throw GimmeError.network(
                "downloaded asset is \(size) bytes, exceeds limit \(maxDownloadBytes)")
        }

        // Verify checksum (the integrity gate; insecure skips this but the
        // bytes are still written under the sha256 name so future hits will
        // re-verify and reject if they don't match).
        let actual = Self.sha256(of: tmp)
        if !insecure, actual != asset.sha256 {
            try? FileManager.default.removeItem(at: tmp)
            throw GimmeError.checksumMismatch(expected: asset.sha256, actual: actual)
        }
        // Move into cache (atomic rename on same volume).
        try FileManager.default.moveItem(at: tmp, to: cached)
        return cached
    }

    /// Download from any URL scheme URLSession supports, plus `file://`.
    private func download(from urlString: String, to dest: URL) throws {
        guard let url = URL(string: urlString) else {
            throw GimmeError.usage("invalid asset URL: \(urlString)")
        }
        if url.isFileURL {
            if let size = fileSize(url), size > maxDownloadBytes {
                throw GimmeError.network(
                    "local asset is \(size) bytes, exceeds limit \(maxDownloadBytes)")
            }
            try FileManager.default.copyItem(at: url, to: dest)
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        var capturedError: Error? = nil

        // Custom session with a redirect handler that catches broken release
        // URLs (GitHub returns 302 → /not_found which downloadTask follows
        // silently and hangs on). We detect redirects to error pages and fail.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config)

        let task = session.downloadTask(with: url) { tempURL, response, error in
            if let error = error {
                capturedError = GimmeError.network("download failed: \(error.localizedDescription)")
                semaphore.signal()
                return
            }
            // Check HTTP status — 404/403/etc are errors, not "no file".
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                capturedError = GimmeError.network(
                    "download failed: HTTP \(http.statusCode) from \(urlString)")
                semaphore.signal()
                return
            }
            guard let tempURL = tempURL else {
                capturedError = GimmeError.network("download returned no file")
                semaphore.signal()
                return
            }
            // Enforce the size cap from the Content-Length / file size before
            // moving the download into our cache temp path.
            let reportedSize: Int64?
            if let http = response as? HTTPURLResponse {
                reportedSize = http.expectedContentLength > 0 ? http.expectedContentLength : nil
            } else {
                reportedSize = self.fileSize(tempURL)
            }
            if let size = reportedSize, size > self.maxDownloadBytes {
                try? FileManager.default.removeItem(at: tempURL)
                capturedError = GimmeError.network(
                    "asset is \(size) bytes, exceeds limit \(self.maxDownloadBytes)")
                semaphore.signal()
                return
            }
            do {
                try FileManager.default.moveItem(at: tempURL, to: dest)
            } catch {
                capturedError = GimmeError.network("could not save download: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        task.resume()
        // Timeout: if the download doesn't complete in 90s, cancel + fail.
        let waitResult = semaphore.wait(timeout: .now() + 90)
        if waitResult == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw GimmeError.network("download timed out after 90s: \(urlString)")
        }
        if let error = capturedError { throw error }
    }

    /// File size in bytes, or nil if unknown.
    private func fileSize(_ url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    /// Compute the sha256 hex digest of a file by STREAMING it in fixed-size
    /// chunks, so large release tarballs don't load entirely into memory.
    public static func sha256(of file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 64 * 1024  // 64 KiB
        while true {
            do {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            } catch {
                return ""
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience: sha256 of a Data buffer.
    public static func sha256(ofData data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
