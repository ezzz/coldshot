# MVP 2 — monthly archive UX and tolerant long runs

## Goal

Make multi-hour, 100 GB-class macOS campaigns understandable and resilient without weakening archive integrity. ColdShot continues past isolated source-asset errors, summarizes coverage by month, and writes new archives into Finder-friendly month directories. No Photos mutation or deletion API is introduced.

## Recoverable issues

A recoverable asset error is retried once from a fresh source request. If it still fails, ColdShot persists the asset identifier, creation date, category, user message, diagnostic details, and attempt count. No manifest is committed for that asset and the transfer proceeds.

Recoverable categories include an isolated hash mismatch, a PhotoKit resource-inventory change, a missing asset, an asset that left the selection, or an asset with no exportable resources.

The campaign pauses when the tenth distinct unresolved asset is recorded. The user can inspect the issue list and use **Réessayer les écarts**; already verified assets are not transferred again.

The following remain immediate stop conditions: destination unavailable, write or capacity failure, Photos authorization/library failure, journal write/decoding failure, existing-file or manifest conflict, and corruption of a previously committed archive.

## Monthly dashboard

The automatic workflow presents years expandable into months. Each month shows:

- photo and video counts;
- indicative volume range;
- archived count and unresolved issue count;
- one labelled state: recent, to archive, in progress, partial, archived and verified at transfer, or attention required;
- an action to use the end of that month as the inclusive automatic target;
- a Finder action once a month directory exists.

Colors are secondary reinforcement only; every state has an icon and text. A custom inclusive date range remains available for event-sized exports and can legitimately produce a partially archived month.

## Archive layout

New jobs use layout version 2:

```text
ColdShotArchive/assets/2023/01/
ColdShotArchive/assets/2023/02/
ColdShotArchive/assets/2023/03/
```

Undated assets use `ColdShotArchive/assets/Sans date/`. Existing legacy and yearly manifests remain readable, resumable with their original writer, and are never migrated automatically.

## ETA and capacity

ETA remains hidden for the first 20 complete samples. A trimmed rolling window feeds a slow moving average; the visible value is rounded to ten minutes, updated at most once per minute, and changes only when the difference is meaningful.

Destination reachability is independent from capacity reporting. Local capacity can produce a blocking warning when even the low estimate does not fit. SMB-reported capacity is labelled indicative; unknown SMB capacity is neutral. Actual write, mount, permission, or out-of-space errors still stop immediately.

## Validation gates

1. One to nine recoverable asset failures do not prevent later assets from being archived.
2. The tenth failure persists and pauses before the eleventh asset.
3. Relaunch preserves the same issue list and retry counts.
4. Retrying issues can complete the campaign without rereading already verified assets.
5. A fatal destination or archive-integrity error always stops on the first occurrence.
6. A cutoff selected on a month includes that full month and excludes the next.
7. New media paths use `year/month`; old layouts remain verifiable.
8. SMB capacity lookup failure does not mark an existing mounted directory unavailable.
9. Green monthly status never enables deletion.
