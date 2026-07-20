# Fidelity matrix

Status values: `untested`, `supported`, `degraded`, `excluded`.

| Asset family | Required fixtures | Export | Restore | Metadata comparison | Status |
|---|---|---:|---:|---|---|
| JPEG | original and edited | pending | pending | date, location, favorite | untested |
| HEIC/HDR | original and edited | pending | pending | content type, dimensions | untested |
| Video | short and large | pending | pending | duration, creation date | untested |
| Live Photo | original and edited | pending | pending | still/video pairing | untested |
| RAW+JPEG | paired capture | pending | pending | both underlying resources | untested |
| Burst | representative burst | pending | pending | burst grouping | untested |
| Referenced asset | source on external volume | pending | pending | offline behavior | untested |
| Shared Album | contributor and subscriber | pending | n/a | provenance and resolution | excluded pending research |
| Shared Library | owned and contributed by another participant | pending | n/a | ownership and delete semantics | excluded pending research |

An asset family must not become deletion-eligible until export and restore are both `supported` with documented metadata differences.

