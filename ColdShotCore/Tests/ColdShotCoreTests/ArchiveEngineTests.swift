import Foundation
import Testing
@testable import ColdShotCore

@Suite("Archive engine")
struct ArchiveEngineTests {
    @Test("SHA-256 matches the standard abc vector")
    func knownDigest() {
        #expect(
            SHA256Hasher.hash(data: Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("Every resource is verified and represented in the manifest")
    func archivesMultipleResources() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let plan = samplePlan()
        let source = InMemorySource(values: [
            "photo": [Data("hello ".utf8), Data("photo".utf8)],
            "paired-video": [Data("paired video".utf8)]
        ])

        let manifest = try await ArchiveEngine().archive(
            asset: plan,
            source: source,
            destination: destination
        )

        #expect(manifest.schemaVersion == 3)
        #expect(manifest.storageLayoutVersion == .yearMonth)
        #expect(manifest.sourceRevisionIdentifier == ArchiveEngine.sourceRevisionIdentifier(for: plan))
        #expect(manifest.sourceAsset == plan)
        #expect(manifest.resources.count == 2)
        #expect(manifest.resources.map(\.byteCount) == [11, 12])

        for resource in manifest.resources {
            let url = destination.appendingPathComponent(resource.relativePath)
            let digest = try SHA256Hasher.hashFile(at: url)
            #expect(digest.digest == resource.sha256)
            #expect(!FileManager.default.fileExists(atPath: url.path + ".partial"))
        }
    }

    @Test("Retry removes a stale partial and completes")
    func resumesAfterInjectedFailure() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let plan = samplePlan(resourceCount: 1)
        let source = InMemorySource(values: ["photo": [Data("retry me".utf8)]])
        let failingEngine = ArchiveEngine(faultInjector: { checkpoint in
            if checkpoint == .sourceCompleted(resourceIdentifier: "photo") {
                throw InjectedFailure.expected
            }
        })

        await #expect(throws: InjectedFailure.expected) {
            try await failingEngine.archive(asset: plan, source: source, destination: destination)
        }

        let partials = try recursiveFiles(in: destination).filter { $0.pathExtension == "partial" }
        #expect(partials.count == 1)

        let manifest = try await ArchiveEngine().archive(asset: plan, source: source, destination: destination)
        #expect(manifest.resources.count == 1)
        #expect(try recursiveFiles(in: destination).allSatisfy { $0.pathExtension != "partial" })
    }

    @Test(
        "Every commit checkpoint is retry-safe",
        arguments: [
            ArchiveCheckpoint.partialCreated(resourceIdentifier: "photo"),
            .sourceCompleted(resourceIdentifier: "photo"),
            .destinationVerified(resourceIdentifier: "photo"),
            .resourceCommitted(resourceIdentifier: "photo"),
            .manifestCommitted
        ]
    )
    func everyCheckpointIsRetrySafe(checkpointToFail: ArchiveCheckpoint) async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let plan = samplePlan(resourceCount: 1)
        let source = InMemorySource(values: ["photo": [Data("checkpoint".utf8)]])
        let failingEngine = ArchiveEngine(faultInjector: { checkpoint in
            if checkpoint == checkpointToFail {
                throw InjectedFailure.expected
            }
        })

        await #expect(throws: InjectedFailure.expected) {
            try await failingEngine.archive(asset: plan, source: source, destination: destination)
        }

        let manifest = try await ArchiveEngine().archive(asset: plan, source: source, destination: destination)
        #expect(manifest.resources.count == 1)
        #expect(try recursiveFiles(in: destination).allSatisfy { $0.pathExtension != "partial" })
    }

    @Test("A complete valid manifest makes reruns idempotent")
    func completedArchiveDoesNotReadSourceAgain() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let plan = samplePlan(resourceCount: 1)
        let source = InMemorySource(values: ["photo": [Data("stable".utf8)]])
        let first = try await ArchiveEngine().archive(asset: plan, source: source, destination: destination)

        let second = try await ArchiveEngine().archive(
            asset: plan,
            source: AlwaysFailingSource(),
            destination: destination
        )
        #expect(second == first)
    }

    @Test("A PhotoKit modification-date refresh does not invalidate an archive")
    func modificationDateRefreshRemainsIdempotent() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let initialPlan = samplePlan(resourceCount: 1)
        let source = InMemorySource(values: ["photo": [Data("stable".utf8)]])
        let first = try await ArchiveEngine().archive(
            asset: initialPlan,
            source: source,
            destination: destination
        )
        let refreshedPlan = ArchiveAssetPlan(
            assetIdentifier: initialPlan.assetIdentifier,
            creationDate: initialPlan.creationDate,
            modificationDate: Date(timeIntervalSince1970: 1_800_000_000),
            mediaKind: initialPlan.mediaKind,
            resources: initialPlan.resources
        )

        let second = try await ArchiveEngine().archive(
            asset: refreshedPlan,
            source: AlwaysFailingSource(),
            destination: destination
        )

        #expect(second == first)
    }

    @Test("Schema 2 manifests decode without schema 3 revision fields")
    func readsSchemaTwoWithoutRevisionFields() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plan = samplePlan(resourceCount: 1)
        let current = try await ArchiveEngine().archive(
            asset: plan,
            source: InMemorySource(values: ["photo": [Data("legacy-schema-two".utf8)]]),
            destination: destination
        )
        let schemaTwo = ArchiveManifest(
            schemaVersion: 2,
            storageLayoutVersion: .yearly,
            storageYear: current.storageYear,
            archiveIdentifier: current.archiveIdentifier,
            archivedAt: current.archivedAt,
            sourceAsset: current.sourceAsset,
            resources: current.resources
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let manifestURL = destination.appendingPathComponent(
            ArchiveEngine.manifestRelativePath(for: plan)
        )
        try encoder.encode(schemaTwo).write(to: manifestURL, options: .atomic)

        let reopened = try await ArchiveEngine().archive(
            asset: plan,
            source: AlwaysFailingSource(),
            destination: destination
        )
        #expect(reopened.schemaVersion == 2)
        #expect(reopened.sourceRevisionIdentifier == nil)
    }

    @Test("A real resource inventory change creates an immutable revision")
    func archivesChangedResourceInventoryAsRevision() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let initialPlan = samplePlan(resourceCount: 1)
        let first = try await ArchiveEngine().archive(
            asset: initialPlan,
            source: InMemorySource(values: ["photo": [Data("stable".utf8)]]),
            destination: destination
        )
        let changedPlan = ArchiveAssetPlan(
            assetIdentifier: initialPlan.assetIdentifier,
            creationDate: initialPlan.creationDate,
            modificationDate: initialPlan.modificationDate,
            mediaKind: initialPlan.mediaKind,
            resources: [
                ArchiveResourcePlan(
                    resourceIdentifier: "photo",
                    originalFilename: "DIFFERENT.HEIC",
                    resourceType: "photo",
                    uniformTypeIdentifier: "public.heic"
                )
            ]
        )

        let second = try await ArchiveEngine().archive(
            asset: changedPlan,
            source: InMemorySource(values: ["photo": [Data("changed".utf8)]]),
            destination: destination
        )

        #expect(second.schemaVersion == 3)
        #expect(second.previousManifestRelativePath == ArchiveEngine.manifestRelativePath(for: initialPlan))
        #expect(second.sourceRevisionIdentifier != first.sourceRevisionIdentifier)
        #expect(second.resources[0].relativePath != first.resources[0].relativePath)
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(first.resources[0].relativePath).path
        ))
        let revisionIdentifier = try #require(second.sourceRevisionIdentifier)
        let revisionPath = ArchiveEngine.revisionManifestRelativePath(
            for: changedPlan,
            sourceRevisionIdentifier: revisionIdentifier
        )
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(revisionPath).path
        ))

        let idempotent = try await ArchiveEngine().archive(
            asset: changedPlan,
            source: AlwaysFailingSource(),
            destination: destination
        )
        #expect(idempotent == second)

        try FileManager.default.removeItem(
            at: destination.appendingPathComponent(ArchiveEngine.manifestRelativePath(for: initialPlan))
        )
        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngine().verifyManifest(
                relativePath: revisionPath,
                destination: destination
            )
        }
    }

    @Test("Schema 3 filenames use a short deterministic suffix")
    func usesShortReadableSuffix() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plan = samplePlan(resourceCount: 1)
        let manifest = try await ArchiveEngine().archive(
            asset: plan,
            source: InMemorySource(values: ["photo": [Data("readable".utf8)]]),
            destination: destination
        )
        let name = try #require(manifest.resources.first?.relativePath.split(separator: "/").last)
        #expect(name.contains("--"))
        #expect(!name.contains(String(SHA256Hasher.hash(data: Data(plan.assetIdentifier.utf8)).prefix(32))))
        #expect(name.utf8.count < 140)
    }

    @Test("The archive catalog discovers committed manifests")
    func discoversArchivedAssetIdentifiers() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plan = samplePlan(resourceCount: 1)
        _ = try await ArchiveEngine().archive(
            asset: plan,
            source: InMemorySource(values: ["photo": [Data("catalogued".utf8)]]),
            destination: destination
        )

        let identifiers = try await ArchiveEngine().cataloguedAssetIdentifiers(destination: destination)

        #expect(identifiers == Set([plan.assetIdentifier]))
    }

    @Test("New archives store colliding original names directly in one monthly media directory")
    func storesAssetsInOneMonthDirectoryWithoutFilenameCollisions() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let firstPlan = samplePlan(assetIdentifier: "first-asset", resourceCount: 1)
        let secondPlan = samplePlan(assetIdentifier: "second-asset", resourceCount: 1)

        let first = try await ArchiveEngine().archive(
            asset: firstPlan,
            source: InMemorySource(values: ["photo": [Data("first".utf8)]]),
            destination: destination
        )
        let second = try await ArchiveEngine().archive(
            asset: secondPlan,
            source: InMemorySource(values: ["photo": [Data("second".utf8)]]),
            destination: destination
        )

        let firstURL = destination.appendingPathComponent(first.resources[0].relativePath)
        let secondURL = destination.appendingPathComponent(second.resources[0].relativePath)
        #expect(firstURL.deletingLastPathComponent() == secondURL.deletingLastPathComponent())
        #expect(firstURL.lastPathComponent != secondURL.lastPathComponent)
        #expect(firstURL.path.contains("/ColdShotArchive/assets/2023/11/"))
        #expect(try Data(contentsOf: firstURL) == Data("first".utf8))
        #expect(try Data(contentsOf: secondURL) == Data("second".utf8))
    }

    @Test("MVP 1 still discovers and validates a legacy per-asset archive")
    func validatesLegacyPerAssetArchive() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plan = samplePlan(resourceCount: 1)
        let first = try await ArchiveEngine().archive(
            asset: plan,
            source: InMemorySource(values: ["photo": [Data("legacy".utf8)]]),
            destination: destination,
            layout: .legacyPerAsset
        )
        let refreshedPlan = ArchiveAssetPlan(
            assetIdentifier: plan.assetIdentifier,
            creationDate: Date(timeIntervalSince1970: 1_735_689_600),
            modificationDate: Date(timeIntervalSince1970: 1_900_000_000),
            mediaKind: plan.mediaKind,
            resources: plan.resources
        )

        let second = try await ArchiveEngine().archive(
            asset: refreshedPlan,
            source: AlwaysFailingSource(),
            destination: destination
        )
        let relativeManifest = try await ArchiveEngine().committedManifestRelativePath(
            for: refreshedPlan,
            destination: destination
        )

        #expect(first.schemaVersion == 1)
        #expect(second == first)
        #expect(relativeManifest.hasSuffix("/manifest.json"))
        #expect(
            try await ArchiveEngine().cataloguedAssetIdentifiers(destination: destination)
                == Set([plan.assetIdentifier])
        )
    }

    @Test(
        "Manifest resource paths cannot escape the selected destination",
        arguments: ["../outside-user-file", "/tmp/outside-user-file"]
    )
    func rejectsEscapingManifestResourcePath(relativePath: String) async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plan = samplePlan(resourceCount: 1)
        let manifest = ArchiveManifest(
            storageYear: "2023",
            sourceAsset: plan,
            resources: [
                ArchivedResource(
                    resourceIdentifier: "photo",
                    originalFilename: "IMG_0001.HEIC",
                    resourceType: "photo",
                    uniformTypeIdentifier: "public.heic",
                    relativePath: relativePath,
                    byteCount: 1,
                    sha256: String(repeating: "0", count: 64)
                )
            ]
        )
        let manifestURL = destination.appendingPathComponent(ArchiveEngine.manifestRelativePath(for: plan))
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(manifest).write(to: manifestURL)

        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngine().archive(
                asset: plan,
                source: AlwaysFailingSource(),
                destination: destination
            )
        }
    }

    @Test("Manifest resource symlinks cannot escape the selected destination")
    func rejectsEscapingManifestResourceSymlink() async throws {
        let destination = try makeTemporaryDirectory()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColdShotOutside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("outside".utf8).write(to: outside)
        let linkURL = destination.appendingPathComponent("resource-link")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outside)

        let plan = samplePlan(resourceCount: 1)
        let manifest = ArchiveManifest(
            storageYear: "2023",
            sourceAsset: plan,
            resources: [
                ArchivedResource(
                    resourceIdentifier: "photo",
                    originalFilename: "IMG_0001.HEIC",
                    resourceType: "photo",
                    uniformTypeIdentifier: "public.heic",
                    relativePath: "resource-link",
                    byteCount: 7,
                    sha256: SHA256Hasher.hash(data: Data("outside".utf8))
                )
            ]
        )
        let manifestURL = destination.appendingPathComponent(ArchiveEngine.manifestRelativePath(for: plan))
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(manifest).write(to: manifestURL)

        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngine().archive(
                asset: plan,
                source: AlwaysFailingSource(),
                destination: destination
            )
        }
    }

    @Test("Manifest symlinks cannot escape the selected destination")
    func rejectsEscapingManifestSymlink() async throws {
        let destination = try makeTemporaryDirectory()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColdShotOutsideManifest-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("{}".utf8).write(to: outside)
        let plan = samplePlan(resourceCount: 1)
        let manifestURL = destination.appendingPathComponent(ArchiveEngine.manifestRelativePath(for: plan))
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: manifestURL, withDestinationURL: outside)

        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngine().archive(
                asset: plan,
                source: AlwaysFailingSource(),
                destination: destination
            )
        }
    }

    @Test("Yearly media filenames remain within filesystem component limits")
    func truncatesLongUnicodeFilenames() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let base = samplePlan(resourceCount: 1)
        let plan = ArchiveAssetPlan(
            assetIdentifier: base.assetIdentifier,
            creationDate: base.creationDate,
            modificationDate: base.modificationDate,
            mediaKind: base.mediaKind,
            resources: [
                ArchiveResourcePlan(
                    resourceIdentifier: "photo",
                    originalFilename: String(repeating: "é", count: 300) + ".HEIC",
                    resourceType: "photo",
                    uniformTypeIdentifier: "public.heic"
                )
            ]
        )

        let manifest = try await ArchiveEngine().archive(
            asset: plan,
            source: InMemorySource(values: ["photo": [Data("long-name".utf8)]]),
            destination: destination
        )
        let filename = try #require(manifest.resources.first?.relativePath.split(separator: "/").last)

        #expect(filename.utf8.count <= 255)
    }

    @Test("Yearly media filenames avoid characters rejected by common SMB servers")
    func createsPortableSMBFilenames() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let base = samplePlan(resourceCount: 1)
        let plan = ArchiveAssetPlan(
            assetIdentifier: base.assetIdentifier,
            creationDate: base.creationDate,
            modificationDate: base.modificationDate,
            mediaKind: base.mediaKind,
            resources: [
                ArchiveResourcePlan(
                    resourceIdentifier: "photo",
                    originalFilename: " bad?name*\"<>|.JPG ",
                    resourceType: "photo",
                    uniformTypeIdentifier: "public.jpeg"
                )
            ]
        )

        let manifest = try await ArchiveEngine().archive(
            asset: plan,
            source: InMemorySource(values: ["photo": [Data("portable".utf8)]]),
            destination: destination
        )
        let filename = try #require(manifest.resources.first?.relativePath.split(separator: "/").last)

        #expect(filename.allSatisfy { !"/:\\?*\"<>|".contains($0) })
        #expect(!filename.hasSuffix("."))
        #expect(!filename.hasSuffix(" "))
    }

    @Test("A source inventory change before manifest commit leaves no committed manifest")
    func rejectsInventoryChangeDuringTransfer() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let plan = samplePlan(resourceCount: 1)
        let source = InventoryChangingSource(data: Data("changing".utf8))

        await #expect(throws: InjectedFailure.expected) {
            try await ArchiveEngine().archive(asset: plan, source: source, destination: destination)
        }

        let manifestURL = destination.appendingPathComponent(ArchiveEngine.manifestRelativePath(for: plan))
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))
    }

    @Test("Corruption of a committed resource is rejected")
    func rejectsCorruptedArchive() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let plan = samplePlan(resourceCount: 1)
        let source = InMemorySource(values: ["photo": [Data("original".utf8)]])
        let manifest = try await ArchiveEngine().archive(asset: plan, source: source, destination: destination)
        let resourceURL = destination.appendingPathComponent(manifest.resources[0].relativePath)
        try Data("corrupt".utf8).write(to: resourceURL)

        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngine().archive(asset: plan, source: source, destination: destination)
        }
        #expect(
            try await ArchiveEngine().cataloguedAssetIdentifiers(destination: destination).isEmpty
        )
    }

    @Test("An unmanifested conflicting final file is never overwritten")
    func rejectsExistingFileConflict() async throws {
        let destination = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }

        let plan = samplePlan(resourceCount: 1)
        let firstSource = InMemorySource(values: ["photo": [Data("first".utf8)]])
        let first = try await ArchiveEngine().archive(asset: plan, source: firstSource, destination: destination)
        let manifestURL = destination.appendingPathComponent(
            ArchiveEngine.manifestRelativePath(for: plan)
        )
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        try FileManager.default.removeItem(at: manifestURL)

        let secondSource = InMemorySource(values: ["photo": [Data("second".utf8)]])
        await #expect(throws: ArchiveError.self) {
            try await ArchiveEngine().archive(asset: plan, source: secondSource, destination: destination)
        }

        let finalURL = destination.appendingPathComponent(first.resources[0].relativePath)
        #expect(try Data(contentsOf: finalURL) == Data("first".utf8))
    }

    private func samplePlan(
        assetIdentifier: String = "test-asset/local-id",
        resourceCount: Int = 2
    ) -> ArchiveAssetPlan {
        let resources = [
            ArchiveResourcePlan(
                resourceIdentifier: "photo",
                originalFilename: "IMG/0001.HEIC",
                resourceType: "photo",
                uniformTypeIdentifier: "public.heic"
            ),
            ArchiveResourcePlan(
                resourceIdentifier: "paired-video",
                originalFilename: "IMG_0001.MOV",
                resourceType: "pairedVideo",
                uniformTypeIdentifier: "com.apple.quicktime-movie"
            )
        ]
        return ArchiveAssetPlan(
            assetIdentifier: assetIdentifier,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: Date(timeIntervalSince1970: 1_700_000_100),
            mediaKind: "image",
            resources: Array(resources.prefix(resourceCount))
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ColdShotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recursiveFiles(in root: URL) throws -> [URL] {
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        return enumerator.compactMap { $0 as? URL }
    }
}

private struct InMemorySource: ArchiveResourceSource {
    let values: [String: [Data]]

    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        let chunks = values[resource.resourceIdentifier] ?? []
        for chunk in chunks {
            try handler(chunk)
        }
    }
}

private struct AlwaysFailingSource: ArchiveResourceSource {
    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        throw InjectedFailure.unexpectedSourceRead
    }
}

private actor InventoryChangingSource: ArchiveResourceSource {
    let data: Data
    private var validationCount = 0

    init(data: Data) {
        self.data = data
    }

    func validate(asset: ArchiveAssetPlan) throws {
        validationCount += 1
        if validationCount > 1 {
            throw InjectedFailure.expected
        }
    }

    func consume(
        resource: ArchiveResourcePlan,
        handler: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        try handler(data)
    }
}

private enum InjectedFailure: Error, Equatable {
    case expected
    case unexpectedSourceRead
}
