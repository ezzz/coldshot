# MVP 1 — large validation campaign

## Purpose

Validate one long, non-destructive macOS archive campaign before any work on Photos deletion. Use a destination whose contents can be inspected and backed up independently. ColdShot still contains no Photos mutation API.

## Before starting

1. Build and run the signed app from Xcode once so Photos and destination permissions are stable.
2. Mount the NAS in Finder, select the final ColdShot destination, and export an initial diagnostic report.
3. Confirm that the automatic cutoff, selected element count, estimated volume, and available destination capacity are plausible.
4. Keep a second copy of any pre-existing ColdShot archive before testing failure scenarios.

## Campaign A — normal long run

1. Select one complete year containing more than 500 elements.
2. Start the automatic archive and confirm that progress crosses 500 without another action.
3. Close the main window and confirm the menu-bar item continues to show global progress, current date, and ETA.
4. Open the window again from the menu bar.
5. Let at least 1,000 elements complete, then use **Mettre en pause**.
6. Quit and relaunch ColdShot, then use **Continuer**. Completed elements must not be downloaded again.
7. Let the campaign finish and run **Vérifier la dernière archive**.

Record total assets, duration, bytes archived, number of pauses, and the exported diagnostic report.

## Campaign B — lifecycle and NAS recovery

Use a disposable test cohort and ensure no other process writes to the destination.

1. Start a campaign, then put the Mac to sleep. ColdShot should request a safe pause before sleep.
2. Wake the Mac, confirm the NAS is mounted, use **Tester la destination** if necessary, then continue.
3. On another small cohort, disconnect the NAS during a transfer. The current resource may leave only a `.partial` file; no manifest may reference it.
4. Remount the NAS, use **Tester la destination**, export the diagnostic report, then continue.
5. Confirm that previously known archive coverage was not cleared while the NAS was absent.

Do not simulate a cable pull on the only copy of valuable archive data.

## Campaign C — source revision

Use one disposable Photos asset already archived by schema 3.

1. Change the asset in Photos so its actual PhotoKit resource inventory changes.
2. Run an incremental synchronization; the asset should be marked for review.
3. Archive it again. ColdShot must create a new immutable manifest revision and new media file paths.
4. Confirm that the previous manifest and previous media bytes still exist unchanged.
5. Run the same archive once more without another edit; it must be idempotent and create no third revision.

## Destination inspection

After all campaigns:

- no committed manifest references a `.partial` file;
- every completed job referenced by the latest campaign exists;
- media remains grouped by year;
- new schema 3 filenames retain the original stem plus a short deterministic suffix;
- schema 1 and schema 2 archives remain readable and untouched;
- the recent-history panel agrees with destination campaign journals;
- a final exported diagnostic report contains no unexplained error.

## Acceptance gate

The MVP 1 validation gate passes only if the normal campaign completes, pause/relaunch resumes without replay, NAS recovery preserves committed work, an explicit hash verification succeeds, and a real source change produces an immutable revision. Any failure should be reported with the exported diagnostic file and the last visible completed/total count.
