# Sprint 0 — feasibility

## Objective

Prove a non-destructive round trip for representative Apple Photos assets:

1. enumerate every `PHAssetResource` belonging to an asset;
2. download iCloud-backed bytes when required;
3. stream each resource to a `.partial` file in a user-selected destination;
4. compute a SHA-256 digest over the PhotoKit stream;
5. close and re-read the destination file to compute an independent digest;
6. commit the file and a versioned manifest only when both digests match;
7. recover safely after cancellation, process termination, or destination loss.

This sprint does **not** delete or modify any Photos asset.

## Exit criteria

- The core test suite passes with Swift strict concurrency enabled.
- The macOS app builds with App Sandbox and Photos Library entitlements.
- A JPEG/HEIC, video, Live Photo, RAW+JPEG, and edited asset have each been inspected.
- Every resource exported by PhotoKit is represented in the manifest.
- A forced failure leaves at most a `.partial` file and a retry succeeds.
- A completed archive is detected and verified without being overwritten.
- A conflicting or corrupted destination is rejected.
- The destination bookmark resolves after relaunch.
- SMB unmount, sleep/wake, iCloud/network failure, and insufficient capacity have documented observed results.

## Manual protocol

Use a dedicated macOS user whose System Photo Library is disposable and is not connected to a personal iCloud account.

If the System Photo Library lives on external storage, the volume must remain mounted throughout the test. Apple supports a directly connected APFS or Mac OS Extended (Journaled) volume; do not host the live library on an SMB/NAS share, a cloud-sync root, or a network/internet-mounted volume.

Before the live permission test, select an Apple Development team for the `ColdShot` target in Xcode. The project intentionally leaves the team blank so it can be cloned safely.

1. Import the fixtures listed in `FIDELITY-MATRIX.md`.
2. Mount the NAS share in Finder.
3. Launch ColdShot and grant Photos access.
4. Choose an empty destination folder on the mounted share.
5. Scan using a cutoff date that includes the fixtures.
6. Select one asset and archive it.
7. Confirm that no `.partial` file remains after success.
8. Compare the manifest resource count with the PhotoKit resource count shown in the app.
9. Disconnect the NAS during a second archive, reconnect it, and retry.
10. Relaunch the app and verify that the stored destination can be resolved.

Record outcomes in the fidelity matrix before expanding the public MVP scope.
