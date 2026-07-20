import CryptoKit
import Foundation

public actor ArchiveEngine {
    public typealias EventHandler = @Sendable (ArchiveEvent) -> Void
    public typealias FaultInjector = @Sendable (ArchiveCheckpoint) throws -> Void

    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let faultInjector: FaultInjector

    public init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        faultInjector: @escaping FaultInjector = { _ in }
    ) {
        self.fileManager = fileManager
        self.now = now
        self.faultInjector = faultInjector
    }

    public func archive(
        asset: ArchiveAssetPlan,
        source: any ArchiveResourceSource,
        destination: URL,
        layout: ArchiveLayoutVersion = .yearMonth,
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> ArchiveManifest {
        try validate(asset: asset, destination: destination)

        let existingManifests = try existingManifests(for: asset, destination: destination)
        var previousManifest: (url: URL, manifest: ArchiveManifest)?
        for url in existingManifests {
            let manifest = try validateManifest(at: url, destination: destination)
            if Self.hasSameStableSource(manifest.sourceAsset, asset) {
                return manifest
            }
            if previousManifest == nil || manifest.archivedAt > previousManifest!.manifest.archivedAt {
                previousManifest = (url, manifest)
            }
        }

        try await source.validate(asset: asset)

        let revisionIdentifier = Self.sourceRevisionIdentifier(for: asset)
        let isRevision = previousManifest != nil
        let mediaDirectory = Self.mediaDirectory(for: asset, layout: layout, destination: destination)
        let manifestURL = Self.manifestURL(
            for: asset,
            layout: layout,
            revisionIdentifier: isRevision ? revisionIdentifier : nil,
            destination: destination
        )
        try fileManager.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        onEvent(.started(resourceCount: asset.resources.count))
        var archivedResources: [ArchivedResource] = []
        archivedResources.reserveCapacity(asset.resources.count)

        for (index, resource) in asset.resources.enumerated() {
            try Task.checkCancellation()
            let filename = layout == .legacyPerAsset
                ? legacyCommittedFilename(index: index, originalFilename: resource.originalFilename)
                : committedFilename(
                    index: index,
                    originalFilename: resource.originalFilename,
                    storageToken: String(revisionIdentifier.prefix(16))
                )
            let finalURL = mediaDirectory.appendingPathComponent(filename, isDirectory: false)
            let partialURL = mediaDirectory.appendingPathComponent(filename + ".partial", isDirectory: false)

            if fileManager.fileExists(atPath: partialURL.path) {
                try fileManager.removeItem(at: partialURL)
            }

            onEvent(.resourceStarted(index: index + 1, total: asset.resources.count, filename: filename))
            let streamed = try await stream(
                resource: resource,
                source: source,
                partialURL: partialURL,
                onEvent: onEvent
            )

            let destinationDigest = try SHA256Hasher.hashFile(at: partialURL)
            guard streamed.digest == destinationDigest.digest,
                  streamed.byteCount == destinationDigest.byteCount else {
                try? fileManager.removeItem(at: partialURL)
                throw ArchiveError.hashMismatch(
                    filename: filename,
                    sourceSHA256: streamed.digest,
                    destinationSHA256: destinationDigest.digest,
                    sourceByteCount: streamed.byteCount,
                    destinationByteCount: destinationDigest.byteCount
                )
            }

            try faultInjector(.destinationVerified(resourceIdentifier: resource.resourceIdentifier))

            if fileManager.fileExists(atPath: finalURL.path) {
                let existingDigest = try SHA256Hasher.hashFile(at: finalURL)
                guard existingDigest.digest == streamed.digest,
                      existingDigest.byteCount == streamed.byteCount else {
                    throw ArchiveError.existingFileConflict(finalURL.path)
                }
                try fileManager.removeItem(at: partialURL)
            } else {
                try fileManager.moveItem(at: partialURL, to: finalURL)
            }

            try faultInjector(.resourceCommitted(resourceIdentifier: resource.resourceIdentifier))

            let relativePath = finalURL.path.replacingOccurrences(
                of: destination.standardizedFileURL.path + "/",
                with: ""
            )
            archivedResources.append(
                ArchivedResource(
                    resourceIdentifier: resource.resourceIdentifier,
                    originalFilename: resource.originalFilename,
                    resourceType: resource.resourceType,
                    uniformTypeIdentifier: resource.uniformTypeIdentifier,
                    relativePath: relativePath,
                    byteCount: streamed.byteCount,
                    sha256: streamed.digest
                )
            )
            onEvent(.resourceVerified(index: index + 1, total: asset.resources.count, filename: filename))
        }

        // PhotoKit can mutate an edited asset while a long iCloud download is running.
        // Never commit a manifest until the complete resource inventory is checked again.
        try await source.validate(asset: asset)

        let manifest = ArchiveManifest(
            schemaVersion: layout == .legacyPerAsset ? 1 : 3,
            storageLayoutVersion: layout == .legacyPerAsset ? nil : layout,
            storageYear: layout == .legacyPerAsset ? nil : Self.yearDirectoryName(for: asset),
            archivedAt: canonicalManifestDate(now()),
            sourceRevisionIdentifier: layout == .legacyPerAsset ? nil : revisionIdentifier,
            previousManifestRelativePath: previousManifest.map {
                relativePath(of: $0.url, destination: destination)
            },
            sourceAsset: asset,
            resources: archivedResources
        )
        try commit(manifest: manifest, to: manifestURL)
        try faultInjector(.manifestCommitted)

        let manifestRelativePath = manifestURL.path.replacingOccurrences(
            of: destination.standardizedFileURL.path + "/",
            with: ""
        )
        onEvent(.completed(manifestRelativePath: manifestRelativePath))
        return manifest
    }

    private func validate(asset: ArchiveAssetPlan, destination: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ArchiveError.destinationIsNotDirectory(destination.path)
        }
        guard !asset.resources.isEmpty else {
            throw ArchiveError.sourceHasNoResources
        }

        var identifiers = Set<String>()
        for resource in asset.resources where !identifiers.insert(resource.resourceIdentifier).inserted {
            throw ArchiveError.duplicateResourceIdentifier(resource.resourceIdentifier)
        }
    }

    private func stream(
        resource: ArchiveResourcePlan,
        source: any ArchiveResourceSource,
        partialURL: URL,
        onEvent: @escaping EventHandler
    ) async throws -> (digest: String, byteCount: Int64) {
        guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
            throw ArchiveError.cannotCreateFile(partialURL.path)
        }

        let sink = try ResourceFileSink(url: partialURL, onEvent: onEvent, resourceIdentifier: resource.resourceIdentifier)
        try faultInjector(.partialCreated(resourceIdentifier: resource.resourceIdentifier))
        do {
            try await source.consume(resource: resource) { data in
                try Task.checkCancellation()
                try sink.consume(data)
            }
        } catch {
            sink.closeAfterFailure()
            throw error
        }

        let result = try sink.finish()
        try faultInjector(.sourceCompleted(resourceIdentifier: resource.resourceIdentifier))
        return result
    }

    private func commit(manifest: ArchiveManifest, to manifestURL: URL) throws {
        guard !fileManager.fileExists(atPath: manifestURL.path) else {
            throw ArchiveError.manifestConflict(manifestURL.path)
        }

        let partialURL = manifestURL.appendingPathExtension("partial")
        if fileManager.fileExists(atPath: partialURL.path) {
            try fileManager.removeItem(at: partialURL)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: partialURL)

        let handle = try FileHandle(forWritingTo: partialURL)
        try handle.synchronize()
        try handle.close()
        try fileManager.moveItem(at: partialURL, to: manifestURL)
    }

    public func verifyManifest(
        relativePath: String,
        destination: URL
    ) throws -> ArchiveManifest {
        let destinationRoot = destination.standardizedFileURL
        let manifestURL = destinationRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard manifestURL.path.hasPrefix(destinationRoot.path + "/") else {
            throw ArchiveError.existingArchiveInvalid("manifest path escapes the archive destination")
        }
        return try validateManifest(at: manifestURL, destination: destinationRoot)
    }

    /// Returns committed manifests whose structure, paths, files, and byte counts
    /// remain coherent. Full content hashes are intentionally reserved for
    /// explicit verification and resume, so catalog refresh stays bounded on NAS.
    public func cataloguedAssetIdentifiers(destination: URL) throws -> Set<String> {
        var identifiers = Set<String>()
        let archiveRoot = destination.appendingPathComponent("ColdShotArchive", isDirectory: true)
        let legacyAssetsRoot = archiveRoot.appendingPathComponent("assets", isDirectory: true)
        if fileManager.fileExists(atPath: legacyAssetsRoot.path) {
            let directChildren = try fileManager.contentsOfDirectory(
                at: legacyAssetsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for child in directChildren {
                try Task.checkCancellation()
                let manifestURL = child.appendingPathComponent("manifest.json", isDirectory: false)
                if let manifest = try? validateManifest(
                    at: manifestURL,
                    destination: destination,
                    verifyContentHashes: false
                ) {
                    identifiers.insert(manifest.sourceAsset.assetIdentifier)
                }
            }
        }

        let currentManifestsRoot = archiveRoot.appendingPathComponent("manifests", isDirectory: true)
        if fileManager.fileExists(atPath: currentManifestsRoot.path) {
            guard let enumerator = fileManager.enumerator(
                at: currentManifestsRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return identifiers }
            for case let url as URL in enumerator where url.pathExtension == "json" {
                try Task.checkCancellation()
                if let manifest = try? validateManifest(
                    at: url,
                    destination: destination,
                    verifyContentHashes: false
                ) {
                    identifiers.insert(manifest.sourceAsset.assetIdentifier)
                }
            }
        }
        return identifiers
    }

    public func committedManifestRelativePath(
        for asset: ArchiveAssetPlan,
        destination: URL
    ) throws -> String {
        for manifestURL in try existingManifests(for: asset, destination: destination) {
            let manifest = try validateManifest(at: manifestURL, destination: destination)
            if Self.hasSameStableSource(manifest.sourceAsset, asset) {
                return relativePath(of: manifestURL, destination: destination)
            }
        }
        throw ArchiveError.existingArchiveInvalid("the committed manifest could not be found")
    }

    private func validateManifest(
        at manifestURL: URL,
        destination: URL,
        verifyContentHashes: Bool = true
    ) throws -> ArchiveManifest {
        do {
            let destinationRoot = destination.standardizedFileURL
            let standardizedManifest = manifestURL.standardizedFileURL
            guard standardizedManifest.path.hasPrefix(destinationRoot.path + "/") else {
                throw ArchiveError.existingArchiveInvalid("manifest path escapes the archive destination")
            }
            let resolvedRoot = destinationRoot.resolvingSymlinksInPath()
            let resolvedManifest = standardizedManifest.resolvingSymlinksInPath()
            guard resolvedManifest.path.hasPrefix(resolvedRoot.path + "/") else {
                throw ArchiveError.existingArchiveInvalid("manifest symlink escapes the archive destination")
            }
            let manifest = try decodeManifest(at: manifestURL)
            guard [1, 2, 3].contains(manifest.schemaVersion) else {
                throw ArchiveError.existingArchiveInvalid("unsupported schema version \(manifest.schemaVersion)")
            }
            if manifest.schemaVersion == 2 {
                guard manifest.storageLayoutVersion == .yearly,
                      manifest.storageYear?.isEmpty == false else {
                    throw ArchiveError.existingArchiveInvalid("schema 2 storage metadata is incomplete")
                }
            }
            if manifest.schemaVersion == 3 {
                guard [.yearly, .yearMonth].contains(manifest.storageLayoutVersion),
                      manifest.storageYear?.isEmpty == false else {
                    throw ArchiveError.existingArchiveInvalid("schema 3 storage metadata is incomplete")
                }
                guard manifest.sourceRevisionIdentifier?.isEmpty == false else {
                    throw ArchiveError.existingArchiveInvalid("schema 3 source revision is missing")
                }
                let expectedRevision = Self.sourceRevisionIdentifier(for: manifest.sourceAsset)
                guard manifest.sourceRevisionIdentifier == expectedRevision else {
                    throw ArchiveError.existingArchiveInvalid("schema 3 source revision does not match its inventory")
                }
                if let previousPath = manifest.previousManifestRelativePath {
                    let previousURL = try safeResourceURL(
                        relativePath: previousPath,
                        destination: destination
                    )
                    guard previousURL.standardizedFileURL != standardizedManifest,
                          fileManager.fileExists(atPath: previousURL.path) else {
                        throw ArchiveError.existingArchiveInvalid("schema 3 previous manifest is missing or recursive")
                    }
                }
            }
            let plannedResourceIdentifiers = Set(manifest.sourceAsset.resources.map(\.resourceIdentifier))
            let archivedResourceIdentifiers = Set(manifest.resources.map(\.resourceIdentifier))
            guard manifest.resources.count == manifest.sourceAsset.resources.count,
                  archivedResourceIdentifiers == plannedResourceIdentifiers else {
                throw ArchiveError.existingArchiveInvalid("manifest resource coverage is incomplete")
            }

            for resource in manifest.resources {
                let fileURL = try safeResourceURL(
                    relativePath: resource.relativePath,
                    destination: destination
                )
                guard fileManager.fileExists(atPath: fileURL.path) else {
                    throw ArchiveError.existingArchiveInvalid("missing resource \(resource.relativePath)")
                }
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                guard Int64(values.fileSize ?? -1) == resource.byteCount else {
                    throw ArchiveError.existingArchiveInvalid("size mismatch for \(resource.relativePath)")
                }
                if verifyContentHashes {
                    let digest = try SHA256Hasher.hashFile(at: fileURL)
                    guard digest.digest == resource.sha256 else {
                        throw ArchiveError.existingArchiveInvalid("hash mismatch for \(resource.relativePath)")
                    }
                }
            }
            return manifest
        } catch let error as ArchiveError {
            throw error
        } catch {
            throw ArchiveError.existingArchiveInvalid(error.localizedDescription)
        }
    }

    private func decodeManifest(at url: URL) throws -> ArchiveManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(ArchiveManifest.self, from: Data(contentsOf: url))
    }

    private func safeResourceURL(relativePath: String, destination: URL) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw ArchiveError.existingArchiveInvalid("resource path is absolute")
        }
        let destinationRoot = destination.standardizedFileURL.resolvingSymlinksInPath()
        let fileURL = destination
            .appendingPathComponent(relativePath, isDirectory: false)
            .standardizedFileURL
        guard fileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
            throw ArchiveError.existingArchiveInvalid("resource path escapes the archive destination")
        }
        let resolved = fileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(destinationRoot.path + "/") else {
            throw ArchiveError.existingArchiveInvalid("resource symlink escapes the archive destination")
        }
        return fileURL
    }

    private static func hasSameStableSource(_ archived: ArchiveAssetPlan, _ current: ArchiveAssetPlan) -> Bool {
        archived.assetIdentifier == current.assetIdentifier
            && archived.mediaKind == current.mediaKind
            && archived.resources == current.resources
    }

    public static func manifestRelativePath(for asset: ArchiveAssetPlan) -> String {
        let token = assetToken(for: asset)
        return "ColdShotArchive/manifests/\(token.prefix(2))/\(token).json"
    }

    public static func revisionManifestRelativePath(
        for asset: ArchiveAssetPlan,
        sourceRevisionIdentifier: String
    ) -> String {
        let token = assetToken(for: asset)
        return "ColdShotArchive/manifests/\(token.prefix(2))/\(token)--\(sourceRevisionIdentifier).json"
    }

    private static func legacyManifestRelativePath(for asset: ArchiveAssetPlan) -> String {
        "ColdShotArchive/assets/\(legacyAssetDirectoryName(for: asset))/manifest.json"
    }

    private static func mediaDirectory(
        for asset: ArchiveAssetPlan,
        layout: ArchiveLayoutVersion,
        destination: URL
    ) -> URL {
        let assetsRoot = destination
            .appendingPathComponent("ColdShotArchive", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
        switch layout {
        case .legacyPerAsset:
            return assetsRoot.appendingPathComponent(legacyAssetDirectoryName(for: asset), isDirectory: true)
        case .yearly:
            return assetsRoot.appendingPathComponent(yearDirectoryName(for: asset), isDirectory: true)
        case .yearMonth:
            guard asset.creationDate != nil else {
                return assetsRoot.appendingPathComponent("Sans date", isDirectory: true)
            }
            return assetsRoot
                .appendingPathComponent(yearDirectoryName(for: asset), isDirectory: true)
                .appendingPathComponent(monthDirectoryName(for: asset), isDirectory: true)
        }
    }

    private static func manifestURL(
        for asset: ArchiveAssetPlan,
        layout: ArchiveLayoutVersion,
        revisionIdentifier: String? = nil,
        destination: URL
    ) -> URL {
        switch layout {
        case .legacyPerAsset:
            return destination.appendingPathComponent(legacyManifestRelativePath(for: asset), isDirectory: false)
        case .yearly, .yearMonth:
            let relativePath = revisionIdentifier.map {
                revisionManifestRelativePath(for: asset, sourceRevisionIdentifier: $0)
            } ?? manifestRelativePath(for: asset)
            return destination.appendingPathComponent(relativePath, isDirectory: false)
        }
    }

    private func existingManifests(for asset: ArchiveAssetPlan, destination: URL) throws -> [URL] {
        var results: [URL] = []
        let current = Self.manifestURL(for: asset, layout: .yearly, destination: destination)
        if fileManager.fileExists(atPath: current.path) { results.append(current) }

        let token = Self.assetToken(for: asset)
        let shard = current.deletingLastPathComponent()
        if fileManager.fileExists(atPath: shard.path) {
            let revisions = try fileManager.contentsOfDirectory(
                at: shard,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter {
                $0.pathExtension == "json"
                    && $0.deletingPathExtension().lastPathComponent.hasPrefix(token + "--")
            }
            results.append(contentsOf: revisions.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }

        let legacy = destination.appendingPathComponent(
            Self.legacyManifestRelativePath(for: asset),
            isDirectory: false
        )
        if fileManager.fileExists(atPath: legacy.path) { results.append(legacy) }

        let legacyAssetsRoot = destination
            .appendingPathComponent("ColdShotArchive", isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
        if let directories = try? fileManager.contentsOfDirectory(
            at: legacyAssetsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ), let matchingDirectory = directories.first(where: {
            $0.lastPathComponent.hasSuffix("-" + Self.legacyAssetToken(for: asset))
        }) {
            let fallback = matchingDirectory.appendingPathComponent("manifest.json", isDirectory: false)
            if fileManager.fileExists(atPath: fallback.path), !results.contains(fallback) {
                results.append(fallback)
            }
        }
        return results
    }

    private static func yearDirectoryName(for asset: ArchiveAssetPlan) -> String {
        guard let creationDate = asset.creationDate else { return "Sans date" }
        let year = Calendar(identifier: .gregorian).component(.year, from: creationDate)
        return String(format: "%04d", year)
    }

    private static func monthDirectoryName(for asset: ArchiveAssetPlan) -> String {
        guard let creationDate = asset.creationDate else { return "Sans date" }
        let month = Calendar(identifier: .gregorian).component(.month, from: creationDate)
        return String(format: "%02d", month)
    }

    private static func assetToken(for asset: ArchiveAssetPlan) -> String {
        String(SHA256Hasher.hash(data: Data(asset.assetIdentifier.utf8)).prefix(32))
    }

    public static func sourceRevisionIdentifier(for asset: ArchiveAssetPlan) -> String {
        var canonical = "asset\u{1F}\(asset.assetIdentifier)\u{1E}media\u{1F}\(asset.mediaKind)"
        for resource in asset.resources {
            canonical += "\u{1E}resource\u{1F}\(resource.resourceIdentifier)"
            canonical += "\u{1F}\(resource.originalFilename)"
            canonical += "\u{1F}\(resource.resourceType)"
            canonical += "\u{1F}\(resource.uniformTypeIdentifier)"
        }
        return SHA256Hasher.hash(data: Data(canonical.utf8))
    }

    private static func legacyAssetDirectoryName(for asset: ArchiveAssetPlan) -> String {
        let year = asset.creationDate.map {
            Calendar(identifier: .gregorian).component(.year, from: $0)
        } ?? 0
        return String(format: "%04d-%@", year, legacyAssetToken(for: asset))
    }

    private static func legacyAssetToken(for asset: ArchiveAssetPlan) -> String {
        String(SHA256Hasher.hash(data: Data(asset.assetIdentifier.utf8)).prefix(20))
    }

    private func canonicalManifestDate(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.down)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private func committedFilename(index: Int, originalFilename: String, storageToken: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?*\"<>|").union(.controlCharacters)
        let sanitized = originalFilename
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: .portableFilenameEdges)
        let fallback = sanitized.isEmpty ? "resource" : sanitized
        let path = fallback as NSString
        let trimmedStem = path.deletingPathExtension.trimmingCharacters(in: .portableFilenameEdges)
        let rawStem = trimmedStem.isEmpty ? "resource" : trimmedStem
        // Leave headroom for macOS filesystem Unicode decomposition and the deterministic suffix.
        let stem = truncateUTF8(rawStem, maximumByteCount: 96)
        let suffix = String(format: "--%@--%02d", storageToken, index + 1)
        let rawExtension = path.pathExtension.trimmingCharacters(in: .portableFilenameEdges)
        let pathExtension = rawExtension.isEmpty ? "" : truncateUTF8(rawExtension, maximumByteCount: 24)
        return pathExtension.isEmpty
            ? stem + suffix
            : stem + suffix + "." + pathExtension
    }

    private func legacyCommittedFilename(index: Int, originalFilename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let sanitized = originalFilename
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let fallback = sanitized.isEmpty ? "resource" : sanitized
        return String(format: "%03d-%@", index + 1, fallback)
    }

    private func truncateUTF8(_ value: String, maximumByteCount: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maximumByteCount else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result.isEmpty ? "resource" : result
    }

    private func relativePath(of url: URL, destination: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(
            of: destination.standardizedFileURL.path + "/",
            with: ""
        )
    }
}

private extension CharacterSet {
    static let portableFilenameEdges = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "."))
}

private final class ResourceFileSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let onEvent: ArchiveEngine.EventHandler
    private let resourceIdentifier: String
    private var hasher = SHA256()
    private var byteCount: Int64 = 0
    private var isClosed = false

    init(
        url: URL,
        onEvent: @escaping ArchiveEngine.EventHandler,
        resourceIdentifier: String
    ) throws {
        self.handle = try FileHandle(forWritingTo: url)
        self.onEvent = onEvent
        self.resourceIdentifier = resourceIdentifier
    }

    func consume(_ data: Data) throws {
        try lock.withLock {
            try handle.write(contentsOf: data)
            hasher.update(data: data)
            byteCount += Int64(data.count)
            onEvent(.resourceBytes(resourceIdentifier: resourceIdentifier, byteCount: byteCount))
        }
    }

    func finish() throws -> (digest: String, byteCount: Int64) {
        try lock.withLock {
            try handle.synchronize()
            try handle.close()
            isClosed = true
            return (SHA256Hasher.hex(hasher.finalize()), byteCount)
        }
    }

    func closeAfterFailure() {
        lock.withLock {
            guard !isClosed else { return }
            try? handle.close()
            isClosed = true
        }
    }

    deinit {
        closeAfterFailure()
    }
}
