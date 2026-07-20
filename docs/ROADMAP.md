# Product roadmap

## Product direction

ColdShot is macOS-first, with a future iPhone companion built on the same archive format and safety rules.

- macOS is the primary platform for large libraries, long-running jobs, direct access to Finder-mounted destinations, and eventual automation.
- iPhone is a companion platform for small libraries and user-initiated cleanup batches without configuring the corresponding Apple Account on a Mac.
- ColdShot never manages Apple Account credentials. PhotoKit exposes the photo library authorized in the current macOS session or on the current iPhone.
- One ColdShot execution context processes one Photos library. Separate Apple Accounts remain separate archive profiles.

## Shared architecture target

`ColdShotCore` remains the shared, platform-neutral layer for:

- archive plans and versioned manifests;
- resource-level SHA-256 verification;
- idempotence, cancellation, and retry state;
- deletion eligibility rules;
- account/profile namespacing in the archive destination.

Platform adapters provide Photos access, destination access, background execution, and user confirmation:

| Concern | macOS | iPhone |
|---|---|---|
| Photos source | System Photo Library for the current macOS session | Photo library of the current iPhone and Apple Account |
| Initial destination | Finder-mounted SMB share or local filesystem | User-selected Files/SMB destination while the app is active |
| Robust network destination | Mounted filesystem | Resumable HTTPS/WebDAV receiver on the Mac or NAS |
| Long-running work | Primary supported environment | Incremental, cancellable, and best-effort |
| Initial deletion UX | Manual after verification | Explicit user action after verification |

Archive data must be separated by source profile, for example:

```text
ColdShot/
├── primary-account/
├── daughter-account/
└── other-account/
```

Names shown to the user are labels, not Apple Account credentials. Durable archive identity relies on the manifest and content hashes, not solely on a device-local PhotoKit identifier.

## Milestones

### Sprint 0 — macOS feasibility

Prove lossless resource enumeration, streaming, verification, retry behavior, destination bookmarks, and NAS failure handling for one asset. No Photos mutation or deletion.

Detailed scope and exit criteria remain in `SPRINT-0.md`.

### Sprint 0.5.1 — inventory and batch feasibility (completed)

- replace the long primary asset list with yearly and cumulative summaries;
- expose an indicative volume range and destination capacity warning;
- let the user choose a bounded cohort using a cutoff year;
- archive assets sequentially in test batches of up to 100;
- persist a destination-side batch journal after every asset;
- resume incomplete jobs without replaying verified assets;
- tolerate PhotoKit-only timestamp refreshes while still rejecting real resource inventory changes;
- exclude committed assets from subsequent bounded cohorts;
- verify the latest completed batch independently from PhotoKit;
- report main progress as completed assets over total assets;
- keep all Photos operations non-destructive.

Detailed scope and exit criteria are in `SPRINT-0.5.md`.

### MVP 1 — macOS archive workflow (validation candidate)

- scan the complete accessible personal System Photo Library independently from selection filters;
- persist a rebuildable local SQLite index and a PhotoKit persistent-change checkpoint in one transaction;
- use PhotoKit deltas after the initial full inventory, with an explicit full-verification fallback;
- make automatic archival before a clearly displayed target year the default workflow;
- retain a custom inclusive date-range workflow for event-sized archives without advancing automatic coverage;
- show a conservative archive-coverage date that cannot skip excluded favorites, hidden items, or media types;
- filter by optional cutoff, standard photos, Live Photos, videos, favorites, and hidden status;
- show exact selected/remaining counts and an indicative resource-volume range;
- archive new media into one human-browsable directory per year;
- preserve V0.5 reading and resume unfinished legacy jobs with their original writer;
- persist and revalidate the selection policy and complete PhotoKit resource inventory around each transfer;
- revalidate already completed records before resuming an interrupted batch;
- archive either the complete remaining selection, one year, or a bounded test cohort;
- chain persistent technical batches automatically with campaign-wide progress and no 500-asset product ceiling;
- persist the complete campaign and its current technical batch on the destination;
- refresh every unfinished PhotoKit plan just before transfer so a pause does not freeze stale resource metadata;
- resume one complete campaign across all remaining batches with a single Continue action;
- keep macOS active and prevent automatic idle sleep during user-initiated campaigns while preserving safe pause and restart checkpoints;
- merge selection, actions, global progress, current asset date, and an approximate ETA into one quiet archive panel;
- provide a user-exportable diagnostic report while keeping technical transfer details out of the main UI;
- verify the latest completed technical batch;
- next validation gate: long-run NAS recovery plus representative restore drills;
- keep deletion unavailable until every eligible asset family passes the fidelity matrix.

The supported account model is one active Apple Account and System Photo Library per macOS session. The same ColdShot binary may be used from separate macOS user sessions, each with its own permissions and configuration.

Detailed scope and manual validation are in `MVP-1.md`.

### MVP 1 — macOS supervision and archive readability (completed for validation)

- menu-bar progress plus pause/continue control while the main window is hidden;
- shorter human-readable schema 3 filenames with deterministic collision protection;
- NAS reachability retest, safe sleep pause, destination-capacity warning, and recent campaign history;
- immutable schema 3 manifest revisions when an already archived PhotoKit asset's real resource inventory changes;
- next gate: complete the large manual validation campaign in `VALIDATION-CAMPAIGN.md`.

This phase remains before the iPhone companion because it completes the long-running macOS workflow that the phone will rely on.

### MVP 2 — monthly archive UX and tolerant long runs (validation candidate)

- retry an isolated recoverable asset failure once, then persist it and continue;
- pause at ten unresolved assets while stopping immediately for destination, permission, journal, manifest, and corruption failures;
- distinguish processed, archived-and-verified, and unresolved counts;
- expose persistent issue details and a dedicated retry action in the app and diagnostic report;
- aggregate the complete inventory by year and month with photo, video, and estimated-volume columns;
- choose the automatic cutoff directly from a month row while retaining the custom date-range workflow;
- derive monthly states for recent, pending, in-progress, partial, archived-at-transfer, and attention-required periods;
- write new destinations using a versioned `Year/Month` layout and keep all legacy/yearly readers;
- update the visible ETA at most once per minute after 20 samples, using robust smoothing and adaptive rounding (ten minutes over one hour, five minutes over ten minutes, then one minute);
- distinguish local capacity, indicative remote capacity, unknown remote capacity, and actual destination unavailability;
- keep the main thread responsive by dropping high-frequency resource-byte events before they reach SwiftUI;
- place the current objective, global progress, and transfer controls before the monthly detail;
- show a persistent yearly status summary with a single expanded year and explicit text actions for each month;
- use flexible table columns across window sizes and keep only five readable, period-based history entries;
- clear ETA at every terminal or paused state and use finer rounding below one hour;
- keep deletion unavailable: a green month is hash-verified at transfer, not deletion-eligible.

Detailed scope and validation notes are in `MVP-2.md`.

### V1.1 — iPhone companion

- add an iOS target sharing `ColdShotCore`;
- request full PhotoKit access only when needed for library-wide filtering and cleanup;
- scan by date and let the user select a small batch;
- download original resources from iCloud on demand;
- archive and verify while the app remains active;
- persist progress after every resource so interruption is safe;
- propose deletion only after verified archival, with an explicit confirmation step.

This milestone targets cases such as cleaning a child's low-volume library directly on their iPhone. It does not promise unattended or indefinite background execution.

### V1.2 — robust iPhone transfer

- introduce a small authenticated HTTPS/WebDAV receiver on the Mac or NAS;
- upload file-backed resources using resumable background transfers where supported;
- return server-side size and SHA-256 verification results;
- reconcile interrupted jobs on the next launch;
- retain direct Files/SMB export as a foreground-only option.

### V2 — automation and multi-device overview

- schedule incremental macOS archival;
- use supported iOS background processing as an enhancement, never as a completion guarantee;
- aggregate read-only status from multiple archive profiles and devices;
- show per-account capacity reclaimed, pending work, errors, and restore confidence;
- support a coordinator UI without storing or switching Apple Account credentials;
- evaluate automatic deletion only after restore drills and deletion eligibility rules are complete.

## Explicit non-goals for the initial MVP

- signing into several Apple Accounts inside ColdShot;
- accessing several iCloud Photos libraries simultaneously from one macOS session;
- storing Apple Account passwords or session tokens;
- guaranteeing long SMB transfers after an iPhone app is suspended;
- treating a single NAS copy as a complete backup;
- deleting assets before resource fidelity and restoration have been demonstrated.

## Roadmap gates

An iPhone feature may advance from experimental to supported only when:

1. its archive manifest is compatible with the macOS implementation;
2. interruption at every transfer checkpoint is safely resumable;
3. NAS/server verification is independent from the source-side hash;
4. representative Live Photo, video, HEIC/HDR, and RAW resources pass export and restore checks;
5. deletion cannot cross an archive profile or proceed after a source/resource mismatch.
