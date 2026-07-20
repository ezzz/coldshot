# ADR 0002 — yearly media layout with immutable legacy support

## Status

Accepted for MVP 1.

## Context

Sprint 0.5 stored each Photos asset and its manifest in a dedicated directory. This was safe for collision avoidance but cumbersome for browsing or reusing exported media. A shared yearly directory creates filename collisions and cannot reuse the old batch assumption that the manifest path is always derived from the current asset plan.

## Decision

- Write new media directly into `ColdShotArchive/assets/<year>/`.
- Keep manifests outside media folders and shard them by a deterministic asset key.
- Preserve a readable sanitized original filename, followed by an asset key and resource index.
- Store the layout version in new manifests and journals.
- Treat a missing journal layout as V0.5 legacy.
- Return and persist the actual committed manifest path.
- Read and verify V0.5 and MVP 1 layouts without moving legacy files.

## Consequences

- Finder browsing is organized by year instead of asset internals.
- Live Photo and edited-resource families remain represented by separate files and one manifest.
- Existing V0.5 archives and resumable jobs remain usable.
- A future physical migration must be an explicit copy-verify operation, never an implicit move.
- The current asset key is local-library identity; portable cross-library identity remains future work.
