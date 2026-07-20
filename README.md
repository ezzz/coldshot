# ColdShot

ColdShot is a macOS-first research prototype for safely archiving Apple Photos resources to a user-selected destination. The product roadmap includes an iPhone companion for smaller, user-initiated cleanup jobs performed directly from the phone that owns the photo library.

The current milestone is the **MVP 2 UX validation candidate**. It is intentionally non-destructive: the app keeps a rebuildable local PhotoKit index, applies persistent changes after the first full scan, offers a monthly automatic cutoff and a custom-period mode, resumes complete campaigns, and writes new media into year/month folders. Isolated asset failures are retried once, persisted as visible issues, and do not stop a long transfer before a safety limit of ten unresolved assets. Its main panel and menu-bar supervisor show global progress, current media date, a deliberately smoothed ETA, and contextual destination-capacity information. It contains no deletion API.

## Requirements

- macOS 15 or later
- Xcode 26.5 stable
- A disposable macOS Photos library for integration testing
- A Finder-mounted SMB destination for the NAS compatibility test

## Build and test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path ColdShotCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project ColdShot.xcodeproj \
  -scheme ColdShot \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Regenerate the Xcode project after adding source files:

```sh
ruby scripts/generate_project.rb
```

The generator preserves an Apple Development team already selected in the existing project. On the first generation, it can be supplied explicitly:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID ruby scripts/generate_project.rb
```

See [MVP 2](docs/MVP-2.md), [MVP 1](docs/MVP-1.md), the [large validation campaign](docs/VALIDATION-CAMPAIGN.md), the [product roadmap](docs/ROADMAP.md), [safety invariants](docs/SAFETY-INVARIANTS.md), the [fidelity matrix](docs/FIDELITY-MATRIX.md), and the current [verification status](docs/VERIFICATION.md).

## License

The source code in this repository is released under the [MIT License](LICENSE).

The ColdShot name, logo, visual identity, and product assets are not granted
under that license. Forks and redistributions should use their own name and
branding unless explicitly authorized.

## Diagnostic logs

ColdShot writes structured logs to the macOS unified log under the subsystem
`com.coldshot.prototype`, with the categories `Workflow`, `PhotoKit`, and
`Archive`. In Xcode, run the app, open the debug console, reproduce the issue,
then search for `ColdShot` or `com.coldshot.prototype`. Copy the lines from
`Campaign started` through the first `error` line when reporting a failure.

PhotoKit asset identifiers and error domain/code are logged publicly so a
failed asset can be identified. Destination paths, filenames, and manifest
paths remain private.

The app also provides **Exporter le rapport…** in the archive panel. This writes a diagnostic text report that can be shared after reproducing a problem without running ColdShot from Xcode.

## First real Photos test

Before requesting Photos access from Xcode, select an Apple Development team for the `ColdShot` target under **Signing & Capabilities**. The repository deliberately does not contain a team identifier, so an unsigned/ad-hoc local build is useful for compilation but is not the reference configuration for TCC permission testing.
