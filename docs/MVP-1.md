# MVP 1 — filtered yearly archive workflow

## Goal

Turn the Sprint 0.5 feasibility probe into a non-destructive archive workflow that can inventory the complete accessible personal System Photo Library, explain the selected cohort, and write human-browsable yearly media folders without invalidating existing V0.5 archives.

## Implemented slice

- one rebuildable SQLite metadata index in Application Support; NAS manifests remain the archive authority;
- an initial complete PhotoKit scan followed by persistent-change deltas, with automatic fallback and a user-requested full verification;
- transactional persistence of each PhotoKit delta and its corresponding change token;
- one complete lightweight inventory of the accessible personal PhotoKit library, with no date filter;
- hidden assets and all burst members included in the inventory;
- filters recalculated in memory without rescanning Photos;
- optional “before year” cutoff;
- independent standard photo, Live Photo, and video filters;
- favorites and hidden assets included by default, with explicit selection toggles;
- a default automatic mode before a target year, plus an inclusive custom date range for event archives;
- a conservative automatic coverage date computed across every media kind, favorite, and hidden asset;
- the chosen filter policy persisted with new batch journals and rechecked before and after each asset transfer;
- exact selected counts and an indicative resource-volume range;
- separate selected, already archived, remaining, and campaign-scope counts;
- complete-selection, single-year, and bounded test scopes;
- no user-visible 500-asset ceiling: large campaigns are automatically split into persistent technical batches of at most 500 assets;
- one destination-side campaign journal stores the complete ordered cohort and current technical batch;
- one Continue action resumes the current batch and automatically processes every later batch in the campaign;
- archive plans prepared only for the next technical batch, then refreshed asset-by-asset immediately before transfer;
- one global completed-assets progress indicator across the whole campaign;
- one merged archive panel showing only the current asset date, verified count, safe pause/continue actions, and an ETA after enough complete samples;
- a rotatable local diagnostic journal and a user-exportable report combining it with this process's ColdShot unified logs;
- a menu-bar supervisor sharing the main model, with compact progress and safe pause/continue controls;
- safe pause on macOS sleep, explicit NAS reachability retest after wake/reconnect, and preservation of known local archive state while the destination is absent;
- recent campaign history read directly from destination journals;
- a macOS user-initiated activity assertion that keeps the app active and prevents automatic idle sleep during archive and verification work;
- direct media storage under one folder per creation year;
- portable deterministic media filenames for common macOS and SMB destinations;
- complete PhotoKit resource inventory revalidation immediately before transfer and before manifest commit;
- destination-only verification of the latest completed batch;
- V0.5 manifest discovery, verification, and interrupted-job resumption;
- no PhotoKit mutation or deletion API.

## Archive layout

New schema 3 MVP 1 archives use:

```text
ColdShotArchive/
├── assets/
│   ├── 2022/
│   │   ├── IMG_0001--<short-revision-key>--01.HEIC
│   │   └── IMG_0001--<short-revision-key>--02.MOV
│   ├── 2023/
│   └── Sans date/
├── manifests/
│   └── <two-key-characters>/
│       ├── <asset-key>.json
│       └── <asset-key>--<source-revision-key>.json
├── jobs/
│   └── <job-uuid>.json
└── campaigns/
    └── <campaign-uuid>.json
```

The original filename remains visible. A deterministic 128-bit SHA-256 prefix plus the resource index prevents two `IMG_0001` assets from colliding in a shared yearly directory. Long names are truncated by UTF-8 byte count before the deterministic suffix is added. Characters commonly rejected by SMB servers are replaced without changing the original name recorded in the manifest.

Manifest schema 3 records the storage layout, storage year, complete source-revision digest, and optional previous-manifest link. A real PhotoKit resource-inventory change creates a new manifest and new media paths; prior bytes are never rewritten. Schema 1 and 2 remain readable. Manifests are sharded outside the media folders so large archives do not mix technical JSON documents with user media or place every manifest in one SMB directory.

The visible suffix uses 16 hexadecimal characters from a deterministic source-revision digest plus the resource index. It is much shorter than the previous 32-character asset suffix. The existing-file check never overwrites different bytes; identical bytes may be reused only if their complete SHA-256 and byte count match.

## V0.5 compatibility

V0.5 remains an immutable legacy layout:

```text
ColdShotArchive/assets/<year>-<asset-key>/manifest.json
```

- MVP 1 discovers and verifies both layouts.
- Existing V0.5 files are never moved automatically.
- A V0.5 journal without a layout field is decoded as legacy.
- Unfinished assets in that legacy journal continue to use the V0.5 writer.
- New jobs use the yearly writer.
- The batch journal stores the manifest path returned after the actual commit instead of recalculating it.

## Selection contract

Analysis and archive selection are separate stages.

1. Analysis fetches lightweight public PhotoKit metadata for the full accessible personal library (`PHAssetSourceType.typeUserLibrary`). Shared-album and synced-source content is not claimed by this milestone.
2. Cutoff and media/protection filters run on the in-memory snapshots.
3. The UI displays exact asset counts and an estimated resource-volume interval.
4. The complete ordered cohort is persisted before transfer, but only the next bounded technical batch asks PhotoKit for full resource inventories.
5. Every unfinished plan is refreshed just before its transfer, including after pause or relaunch; complete and annual campaigns then chain all later batches automatically.
6. ColdShot rechecks the current public protection metadata and the complete resource inventory before copying and again before committing the manifest.

The volume remains an estimate derived from dimensions and duration. It is not an exact iCloud quota-recovery figure.

Destination catalog refresh checks manifest structure, safe paths, file presence, and byte counts so it remains practical on a large NAS. Explicit batch verification and interrupted-job resume additionally re-read SHA-256 content hashes. Catalog presence alone never makes an asset deletion-eligible.

The displayed coverage date means that ColdShot knows a committed archive for every accessible, dated asset up to that point and that each archive was hash-verified when committed. It is not a fresh full-NAS hash pass and never authorizes deletion. With limited Photos access, it describes only the user-authorized subset.

SQLite is a disposable accelerator, not a second archive catalog. If it is lost or corrupt, ColdShot rebuilds source metadata from Photos and archive presence from destination manifests. A changed archived asset is marked for review and schema 3 archives it as an immutable revision.

## Still outside this slice

- restoring assets into Photos;
- proving every row of the fidelity matrix;
- unattended scheduling, relaunch after app termination, and daemon-style execution;
- automatic deletion from Photos or iCloud;
- migration of existing V0.5 media into the yearly layout;
- destination locking across two simultaneous ColdShot processes;
- deleting from Photos or treating the coverage date alone as deletion eligibility;
- automatic retry loops while a NAS remains disconnected; the user explicitly retests and continues;

## Manual validation

1. Re-analyze the real test library and compare the personal-library count with Photos, excluding shared-album and synced-source content.
2. Toggle each media, favorite, hidden, and cutoff filter and verify counts update without another scan.
3. Archive two different assets with the same original filename and inspect the shared yearly folder.
4. Resume the latest incomplete V0.5 job and confirm its remaining files stay in the legacy layout.
5. Start a 10-asset test job and confirm its files appear directly in the yearly layout.
6. Start one complete year containing more than 500 assets and confirm the global progress continues beyond 500 without another click.
7. Minimize ColdShot and confirm the campaign continues while the app remains running; then use “Mettre en pause”, relaunch if desired, and confirm one “Continuer” finishes the current and every later technical batch.
8. Verify the latest completed technical batch from the destination.
9. Relaunch after changing one old asset in Photos and confirm incremental synchronization marks it for review; use “Vérification complète” to exercise the fallback path.
10. Export a diagnostic report without Xcode and confirm it contains workflow events while the main UI remains concise.

The complete pre-release protocol is in `VALIDATION-CAMPAIGN.md`.
