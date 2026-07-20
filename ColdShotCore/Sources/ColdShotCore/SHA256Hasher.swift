import CryptoKit
import Foundation

public enum SHA256Hasher {
    public static func hash(data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    public static func hashFile(at url: URL, chunkSize: Int = 1_048_576) throws -> (digest: String, byteCount: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var byteCount: Int64 = 0

        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data)
            byteCount += Int64(data.count)
        }

        return (hex(hasher.finalize()), byteCount)
    }

    static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

