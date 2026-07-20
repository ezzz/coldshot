import Foundation

public enum ArchiveLayoutVersion: Int, Codable, Equatable, Sendable {
    case legacyPerAsset = 0
    case yearly = 1
    case yearMonth = 2
}

public enum ArchiveFailureDisposition: String, Codable, Equatable, Sendable {
    case recoverableAsset
    case fatal
}

public enum ArchiveFailureCategory: String, Codable, Equatable, Sendable {
    case hashMismatch
    case sourceChanged
    case assetUnavailable
    case sourceHasNoResources
    case selectionChanged
    case destination
    case archiveConflict
    case authorization
    case photoLibrary
    case journal
    case unknown
}

public protocol ArchiveFailureClassifying: Error {
    var archiveFailureDisposition: ArchiveFailureDisposition { get }
    var archiveFailureCategory: ArchiveFailureCategory { get }
}

public struct ArchiveAssetPlan: Codable, Equatable, Sendable {
    public let assetIdentifier: String
    public let creationDate: Date?
    public let modificationDate: Date?
    public let mediaKind: String
    public let resources: [ArchiveResourcePlan]

    public init(
        assetIdentifier: String,
        creationDate: Date?,
        modificationDate: Date?,
        mediaKind: String,
        resources: [ArchiveResourcePlan]
    ) {
        self.assetIdentifier = assetIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.mediaKind = mediaKind
        self.resources = resources
    }
}

public struct ArchiveResourcePlan: Codable, Equatable, Sendable {
    public let resourceIdentifier: String
    public let originalFilename: String
    public let resourceType: String
    public let uniformTypeIdentifier: String

    public init(
        resourceIdentifier: String,
        originalFilename: String,
        resourceType: String,
        uniformTypeIdentifier: String
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.originalFilename = originalFilename
        self.resourceType = resourceType
        self.uniformTypeIdentifier = uniformTypeIdentifier
    }
}

public struct ArchivedResource: Codable, Equatable, Sendable {
    public let resourceIdentifier: String
    public let originalFilename: String
    public let resourceType: String
    public let uniformTypeIdentifier: String
    public let relativePath: String
    public let byteCount: Int64
    public let sha256: String

    public init(
        resourceIdentifier: String,
        originalFilename: String,
        resourceType: String,
        uniformTypeIdentifier: String,
        relativePath: String,
        byteCount: Int64,
        sha256: String
    ) {
        self.resourceIdentifier = resourceIdentifier
        self.originalFilename = originalFilename
        self.resourceType = resourceType
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct ArchiveManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let storageLayoutVersion: ArchiveLayoutVersion?
    public let storageYear: String?
    public let archiveIdentifier: UUID
    public let archivedAt: Date
    /// Stable digest of the complete PhotoKit source inventory for schema 3.
    /// Nil for legacy manifests.
    public let sourceRevisionIdentifier: String?
    /// Previous immutable manifest for the same Photos asset, when this is a revision.
    public let previousManifestRelativePath: String?
    public let sourceAsset: ArchiveAssetPlan
    public let resources: [ArchivedResource]

    public init(
        schemaVersion: Int = 2,
        storageLayoutVersion: ArchiveLayoutVersion? = .yearMonth,
        storageYear: String? = nil,
        archiveIdentifier: UUID = UUID(),
        archivedAt: Date = Date(),
        sourceRevisionIdentifier: String? = nil,
        previousManifestRelativePath: String? = nil,
        sourceAsset: ArchiveAssetPlan,
        resources: [ArchivedResource]
    ) {
        self.schemaVersion = schemaVersion
        self.storageLayoutVersion = storageLayoutVersion
        self.storageYear = storageYear
        self.archiveIdentifier = archiveIdentifier
        self.archivedAt = archivedAt
        self.sourceRevisionIdentifier = sourceRevisionIdentifier
        self.previousManifestRelativePath = previousManifestRelativePath
        self.sourceAsset = sourceAsset
        self.resources = resources
    }
}

public enum ArchiveCheckpoint: Equatable, Sendable {
    case partialCreated(resourceIdentifier: String)
    case sourceCompleted(resourceIdentifier: String)
    case destinationVerified(resourceIdentifier: String)
    case resourceCommitted(resourceIdentifier: String)
    case manifestCommitted
}

public enum ArchiveEvent: Equatable, Sendable {
    case started(resourceCount: Int)
    case resourceStarted(index: Int, total: Int, filename: String)
    case resourceBytes(resourceIdentifier: String, byteCount: Int64)
    case resourceVerified(index: Int, total: Int, filename: String)
    case completed(manifestRelativePath: String)
}

public protocol ArchiveResourceSource: Sendable {
    /// Confirms that the complete source asset still matches the plan.
    /// Sources that cannot change may rely on the default no-op implementation.
    func validate(asset: ArchiveAssetPlan) async throws

    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws
}

public extension ArchiveResourceSource {
    func validate(asset: ArchiveAssetPlan) async throws {}
}

public enum ArchiveError: Error, Equatable, LocalizedError, Sendable {
    case destinationIsNotDirectory(String)
    case sourceHasNoResources
    case duplicateResourceIdentifier(String)
    case cannotCreateFile(String)
    case hashMismatch(
        filename: String,
        sourceSHA256: String,
        destinationSHA256: String,
        sourceByteCount: Int64,
        destinationByteCount: Int64
    )
    case existingFileConflict(String)
    case existingArchiveInvalid(String)
    case manifestConflict(String)

    public var errorDescription: String? {
        switch self {
        case .destinationIsNotDirectory(let path):
            "The archive destination is not a directory: \(path)"
        case .sourceHasNoResources:
            "The Photos asset has no exportable resources."
        case .duplicateResourceIdentifier(let identifier):
            "The asset contains a duplicate resource identifier: \(identifier)"
        case .cannotCreateFile(let path):
            "ColdShot could not create the partial file: \(path)"
        case .hashMismatch(let filename, _, _, _, _):
            "The destination hash does not match the source stream for \(filename)."
        case .existingFileConflict(let path):
            "A different final file already exists at \(path)."
        case .existingArchiveInvalid(let reason):
            "The existing archive could not be validated: \(reason)"
        case .manifestConflict(let path):
            "A manifest already exists and cannot be replaced: \(path)"
        }
    }
}

extension ArchiveError: ArchiveFailureClassifying {
    public var archiveFailureDisposition: ArchiveFailureDisposition {
        switch self {
        case .hashMismatch, .sourceHasNoResources:
            .recoverableAsset
        case .destinationIsNotDirectory, .duplicateResourceIdentifier, .cannotCreateFile,
             .existingFileConflict, .existingArchiveInvalid, .manifestConflict:
            .fatal
        }
    }

    public var archiveFailureCategory: ArchiveFailureCategory {
        switch self {
        case .hashMismatch:
            .hashMismatch
        case .sourceHasNoResources:
            .sourceHasNoResources
        case .destinationIsNotDirectory, .cannotCreateFile:
            .destination
        case .existingFileConflict, .existingArchiveInvalid, .manifestConflict:
            .archiveConflict
        case .duplicateResourceIdentifier:
            .unknown
        }
    }
}
