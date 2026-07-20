# ADR 0001 — Sprint 0 architecture

Status: accepted for the feasibility sprint.

## Decision

- Use Swift 6, SwiftUI, and a macOS 15 deployment target.
- Keep the app target as a thin shell.
- Put archive models, hashing, state transitions, and filesystem behavior in `ColdShotCore`.
- Compile the same `ColdShotCore` sources as both an Xcode framework and a Swift package so unit tests run without an application host.
- Use PhotoKit only in the app adapter.
- Treat a Finder-mounted, user-selected directory as the archive destination.
- Store versioned JSON manifests next to archived resources.
- Defer SQLite until the resource pipeline and manifest contract are proven.

## Rationale

The largest Sprint 0 risks are PhotoKit resource fidelity, sandboxed access to network volumes, and crash-safe filesystem behavior. Adding a database before these contracts are stable would not reduce those risks. A journal database becomes justified when Sprint 1 processes multiple assets and resumes queued jobs.

