# Safety invariants

These rules apply before product features or UI polish.

1. Sprint 0 never calls a PhotoKit change API.
2. Every underlying PhotoKit resource is archived independently.
3. A resource is verified only when the SHA-256 of the incoming PhotoKit byte stream equals the SHA-256 obtained by reopening the destination file.
4. Final files are never overwritten.
5. A conflicting final file stops the archive and is left untouched.
6. A cancellation or handled failure may leave a `.partial` file, but never a committed manifest that references it.
7. The manifest is committed only after every resource is verified and finalized.
8. A completed archive is revalidated from disk before it is treated as idempotently complete.
9. Security-scoped destination access is active only while the destination is in use.
10. No future deletion may be eligible unless the source resource inventory is unchanged, deletion-time metadata rules pass, and a supported restore has been demonstrated. A PhotoKit timestamp refresh alone is not resource identity.
11. Batch execution remains serial. A recoverable asset failure is retried once, then persisted and skipped; destination, authorization, journal, manifest, or archive-corruption failures stop immediately.
12. Batch progress is persisted through an atomic `.partial` journal replacement after every asset transition.
13. A batch journal is orchestration state only; it never makes an asset deletion-eligible without a valid resource manifest.
14. Preflight volume is always labelled as an estimate unless every resource byte has been read and verified.
15. The main progress bar counts processed assets. The UI always reports archived-and-verified and unresolved-issue counts separately; partial resource or byte progress never increments either count.
16. Existing V0.5 files are immutable compatibility inputs; MVP 1 never moves or rewrites them automatically.
17. A journal without a layout version resumes with the legacy per-asset writer; new jobs use the year/month writer, while yearly journals keep their original writer.
18. Shared monthly media filenames include deterministic asset and resource identity, and a collision never permits overwrite.
19. Every manifest and manifest resource path must remain inside the selected destination after standardization and symbolic-link resolution.
20. A mutable source validates its complete resource inventory before transfer and again immediately before manifest commit.
21. New batch journals persist the selection policy; favorites, hidden status, cutoff, and media type are rechecked around every transfer.
22. Resume revalidates every record already marked archived from destination bytes before it skips that record.
23. Catalog refresh may use manifest structure, safe path, presence, and byte-count checks for scale; only explicit verification or resume claims a fresh SHA-256 reread.
24. A large campaign is split only for bounded preparation and checkpointing; every selected index belongs to exactly one ordered technical batch and global progress advances only after a verified asset.
25. Inventory, batch preparation, and resource access use the same personal-library PhotoKit population, including hidden assets and every member of burst sequences; default fetch options must not make an inventoried asset falsely unavailable later.
26. A campaign journal persists the complete ordered cohort before the first technical batch starts; pausing inside one batch never loses the identity of later batches.
27. The current technical batch identifier is committed in the campaign journal before its batch journal is created, so interruption between planning and batch creation remains retryable.
28. Every unfinished asset plan is refreshed from its current PhotoKit asset immediately before transfer. Completed records are never replaced by refreshed source metadata and remain subject to destination SHA-256 verification on resume.
29. A campaign checkpoint is derived from its batch journal after completion, failure, or cooperative cancellation; a crash between those writes is reconciled from the batch journal on the next resume.
30. The local SQLite index is reconstructible cache state only; destination manifests and verified resource bytes remain archive authority.
31. A PhotoKit persistent-change token is committed in the same SQLite transaction as the asset changes it represents. A failure rolls both back.
32. A full inventory captures its PhotoKit token before enumeration so changes occurring during enumeration are replayed by the next delta.
33. An archived asset whose PhotoKit modification signal changes is marked for review; its prior archive is never silently rewritten or treated as current.
34. Automatic coverage is computed across all accessible dated media, including favorites and hidden assets, independently of temporary selection toggles.
35. A displayed coverage date is informational and never deletion eligibility. Limited Photos authorization can establish coverage only for the authorized subset.
36. A real source-inventory change creates a schema 3 revision with new paths and a link to the previous manifest; prior manifests and media are immutable.
37. Schema 3 visible filenames retain a deterministic 64-bit prefix and resource index. An existing path is reused only for identical byte count and complete SHA-256; different bytes stop and are never overwritten.
38. A macOS sleep notification requests the same cooperative checkpoint pause as the user-facing pause action.
39. Destination catalog failure or NAS absence never replaces known local archive identifiers with an empty set.
40. Corrupt batch or campaign JSON fails history/state loading visibly; journal decoding errors are not silently discarded.
41. Recoverable failures are counted by distinct unresolved assets, not by retry attempts. The tenth unresolved asset pauses the campaign before the next asset.
42. A campaign may finish with issues, but an unresolved asset has no committed manifest, remains a hole in coverage, and cannot become deletion-eligible.
43. Retrying issues only resets failed records; already verified records are never downloaded again and remain governed by their committed manifests.
44. Failure details and retry counts are persisted in destination-side journals so relaunching ColdShot cannot hide an unresolved issue.
45. Unknown SMB capacity never makes a reachable destination appear unavailable. A real mount, permission, write, or out-of-space failure still stops immediately.

The SHA-256 comparison proves transfer integrity. It does not make a single NAS copy a backup against future media, controller, theft, or operator failure.
