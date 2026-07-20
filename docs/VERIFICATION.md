# MVP 2 verification status

Last automated verification: 2026-07-18 with Xcode 27 beta and Swift 6.

## Passed

- `ColdShotCore` builds as a host-less Swift package.
- Swift Testing suite passes under strict concurrency.
- Standard SHA-256 vector is correct.
- Multiple resources are written, independently re-read, and represented in the manifest.
- Failures injected after partial creation, source completion, destination verification, final-file commit, and manifest commit are retry-safe.
- Completed archives are idempotently revalidated.
- Corrupted archives and conflicting final files are rejected without overwrite.
- The macOS 15 app target builds with Xcode 26.5.
- The built app is ad-hoc signed and passes deep strict code-signature verification.
- The built app contains the App Sandbox, Photos Library, user-selected read/write, and app-scoped bookmark entitlements.
- The built app launches without a dynamic-link failure.
- No PhotoKit mutation or deletion API is present in the Swift sources.
- Inventory aggregation groups photos, videos, Live Photos, duration, and indicative volume by year and month.
- A monthly cutoff includes the complete selected month and excludes the following month.
- Batch journals are persisted after each asset and completed assets survive a failed-job resume without another source read.
- PhotoKit-only modification-date changes do not invalidate a resource-identical archive.
- Real resource inventory changes still invalidate an existing archive.
- Structurally valid committed manifests with present, size-coherent files are catalogued for subsequent-batch exclusion.
- A completed batch can be independently re-read and SHA-256 verified without a PhotoKit source.
- New resources with colliding original filenames remain distinct in one yearly media directory.
- New default archives place colliding names safely in one `year/month` directory while the yearly writer remains readable.
- Legacy per-asset archives remain discoverable and idempotently verifiable, including after a creation-year change.
- A V0.5 journal with no layout field decodes as legacy.
- Manifest paths that are absolute, escape the destination, or resolve through an escaping symlink are rejected.
- Cutoff, standard-photo, Live Photo, video, favorite, and hidden filters are computed from lightweight snapshots.
- Disabling the cutoff includes assets without creation dates.
- The complete mutable-source inventory is checked before transfer and again before manifest commit.
- Resume rejects a previously completed record whose destination bytes are now corrupt.
- Destination catalog discovery rejects missing or size-incoherent resources without hashing the entire NAS.
- New yearly filenames avoid characters commonly rejected by SMB servers.
- Campaign planning covers 5,000 assets in ten automatic checkpoints and preserves a non-multiple-of-500 remainder without dropping or duplicating indexes.
- A persistent five-asset campaign stopped in its second technical batch resumes that batch, skips its three verified assets, and automatically completes the final batch.
- Batch resume refreshes only unfinished source plans; already archived assets are verified from destination bytes and are not reopened through the source factory.
- The macOS app builds with complete-selection, annual, and bounded-test scopes plus campaign-wide progress.
- The local SQLite index transactionally persists full scans, deltas, deletions, archive status, review status, target cutoff, and PhotoKit checkpoint state.
- A modified archived asset is marked for review and returns to current status only after `markArchived`.
- Custom archive ranges use inclusive calendar days in the UI and half-open bounds internally.
- ETA remains hidden until twenty complete assets, uses a trimmed rolling window, and then applies slow smoothing.
- Schema 3 creates immutable linked revisions for real source-inventory changes while an unchanged rerun remains idempotent.
- Schema 2 manifests decode without schema 3 fields and V0.5/schema 1 behavior remains unchanged.
- New visible media suffixes use a 16-character deterministic revision prefix; collision handling remains no-overwrite.
- Campaign history is derived from destination journals and corrupt journal decoding is surfaced rather than silently skipped.
- The macOS app builds with a shared menu-bar supervisor, sleep/wake handling, NAS reachability retest, and recent history.
- A recoverable asset error is retried once, persisted, and skipped without blocking later assets.
- The tenth unresolved recoverable asset pauses before the eleventh asset.
- A campaign can finish with persistent issues and later retry only failed assets.
- Fatal unknown/destination/archive-integrity failures continue to stop immediately.
- The Swift Testing run contains 47 tests in 6 suites.

## Requires a disposable Photos environment

- TCC authorization and limited-access behavior.
- iCloud-only resource download.
- Resource inventories for HEIC/HDR, video, Live Photo, RAW+JPEG, edited assets, and bursts.
- Security-scoped bookmark resolution after a real relaunch.
- Finder-mounted SMB throughput and rename behavior.
- NAS disconnect/reconnect, macOS sleep/wake, destination-full, and source-modified scenarios.
- Restore fidelity. Restore code is intentionally not part of this first non-destructive export slice.
- Batch behavior with 10, 25, 50, and 100 real PhotoKit assets.
- Destination capacity reporting and insufficient-capacity behavior on the target NAS.
- Complete-inventory comparison including hidden assets and every burst member.
- MVP 2 year/month-layout batches of 10, 100, and 500 real assets.
- One real annual campaign above 500 assets, including minimization, cancellation, and continuation behavior.
- Resume of a real incomplete V0.5 or yearly journal followed by a fresh year/month-layout job.
- One to nine real recoverable PhotoKit errors followed by successful later assets, then issue-only retry.
- Exact safety pause and clear issue presentation on a real tenth unresolved asset.
- Neutral capacity presentation when a mounted SMB share does not expose free space.

## First real-device finding

The initial live test reported `com.apple.photos.error` code `41015` while Photos tried to bind the System Photo Library at `/Volumes/Photos iCloud/PhotosApple/Photothèque.photoslibrary`. This is an unavailable-library failure before ColdShot enumerates assets. The app now checks `PHPhotoLibrary.shared().unavailabilityReason` before issuing a fetch and presents the system error rather than treating the library as empty.

The same availability check runs again immediately before the app fetches an asset or its resources for export. This keeps a volume removal after the scan from being misreported as a missing asset.

A subsequent live test with a local System Photo Library confirmed that ColdShot can enumerate assets using a cutoff date and archive one selected asset to disk.

The first V0.5 batch campaign produced 100 committed manifests containing 158 resources (about 872 MB). An independent destination-side pass found 158 matching SHA-256 values, no mismatch, and no missing file. Five stopped jobs all reported the same false metadata mismatch: PhotoKit had refreshed `modificationDate` while materializing iCloud originals. V0.5.1 removes timestamps from stable resource identity and adds a direct latest-batch verification action. The MVP 1 complete-inventory filters, yearly writer, and real V0.5 resume path still require the live checks listed above.

Do not perform these checks against a personal System Photo Library. Follow the manual protocol in `SPRINT-0.md` from a dedicated macOS account.
