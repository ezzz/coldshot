# Sprint 0.5.1 — inventory and batch feasibility

## Objective

Turn the single-asset Sprint 0 probe into a non-destructive, measurable workflow for choosing and archiving a bounded cohort of old Photos assets.

The sprint must answer four product questions:

1. Can ColdShot summarize a large library without presenting an unusable asset list?
2. Can it give an honest volume range before downloading every original?
3. Can it archive a sequential batch without requiring equivalent free space on the Mac?
4. Can it resume after cancellation, relaunch, or destination failure without replaying verified assets?

This sprint still contains no Photos deletion API.

## Implemented slice

- full-library metadata inventory through PhotoKit;
- yearly photo, video, Live Photo, and video-duration summaries;
- cumulative selection using an “assets before year X” policy;
- explicitly approximate volume ranges derived from public dimensions and durations;
- destination capacity display when the filesystem reports it;
- collapsible asset details capped at 40 visible rows;
- bounded test batches of 10, 25, 50, or 100 assets;
- serial resource streaming through the existing SHA-256 archive engine;
- one JSON batch journal stored on the destination and synchronized after every asset;
- discovery and resumption of the latest incomplete batch;
- preservation of the single-asset probe for fidelity investigation.

## V0.5.1 live-test corrections

- A PhotoKit `modificationDate` refresh caused by materializing an iCloud original no longer invalidates an otherwise identical archive.
- Stable idempotence compares the PhotoKit asset identifier, media kind, and complete resource inventory; creation and modification timestamps remain recorded observations rather than resource identity.
- A real filename, resource type, UTI, resource count, or resource identifier change still stops validation.
- New batches exclude assets that already have a decodable committed manifest on the selected destination.
- The latest completed batch can be verified directly from destination files and SHA-256 values without reading PhotoKit again.
- Batch progress advances only after a complete photo or video asset has been archived and verified; per-resource byte transfer no longer changes the main progress bar.
- Batch errors explicitly direct the user to the persisted resume action.

For safety and responsiveness, the current prototype prepares archive plans for at most the 500 oldest assets. The summary still covers every asset returned by PhotoKit.

## Estimation contract

PhotoKit does not expose a reliable public byte count for every iCloud-backed resource. ColdShot therefore labels preflight volume as an indicative range.

- Image estimates use pixel count and a wide compressed-byte range.
- Live Photo estimates include an additional uncertainty multiplier.
- Video estimates use duration, resolution, and a broad bitrate range.
- Exact byte counts are recorded only while originals are streamed and verified.

The estimate must never be presented as guaranteed reclaimable capacity.

## Batch journal contract

The journal is stored at:

```text
ColdShotArchive/jobs/<job-uuid>.json
```

Each asset is in one of four explicit states: `pending`, `archiving`, `archived`, or `failed`.

- The journal is written through a `.partial` file and atomically replaced.
- An interrupted `archiving` or `failed` asset becomes `pending` on resume.
- An `archived` asset is not read from PhotoKit again; the underlying asset manifest is revalidated by `ArchiveEngine` when necessary.
- A batch stops on the first asset failure to avoid repeating a systemic NAS, capacity, or network error across the cohort.
- A manifest remains the resource-integrity authority; the batch journal is orchestration state, not deletion evidence.
- A structurally valid destination catalog with safe paths, present files, and matching byte counts avoids repeatedly selecting the same oldest assets; explicit batch verification remains responsible for re-reading content hashes.

## Validation protocol

Run each cohort size against a disposable Photos library before using personal data:

1. archive 10 ordinary JPEG/HEIC assets;
2. archive 25 mixed assets including Live Photos and videos;
3. cancel during an iCloud download and resume;
4. quit the app between two assets and resume;
5. unmount and remount the destination during a batch;
6. test a destination with insufficient capacity;
7. rerun a completed asset and confirm source bytes are not downloaded again;
8. restore representative manifests and record results in `FIDELITY-MATRIX.md`.

## Exit criteria

- Inventory counts match Photos for the test library.
- Changing the cutoff year updates cumulative counts without rescanning.
- Estimate ranges are clearly labelled and destination capacity warnings are visible.
- A 100-asset mixed batch completes serially with no orphaned committed manifest.
- Cancellation and relaunch resume from the latest incomplete asset.
- A NAS failure leaves the previous journal and verified manifests readable.
- Unit tests cover aggregation, estimation scaling, batch persistence, and failed-job resumption.
- The full Swift package tests and macOS build pass under Swift 6 strict concurrency.
