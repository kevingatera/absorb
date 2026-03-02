# Continuity (homelab-upstream)

## Session setup (2026-03-02)

- Created branch `homelab-upstream` from `upstream/main` (`538996f`).
- Branch tracking: `homelab-upstream...upstream/main`.
- Preserved existing uncommitted work by stashing tracked + untracked files:
  - `stash@{0}`: `On homelab: wip: pre-homelab-upstream setup 2026-03-02`

## Migration intent

- Re-apply homelab-specific commits from `homelab` onto `homelab-upstream` one commit at a time.
- For each candidate commit, verify whether upstream already includes equivalent behavior before cherry-picking.

## Candidate commit queue (from `upstream/main..homelab`)

- `fee7730` Fix personalized refresh overhead
- `47eb5c1` Add homelab side-by-side install support
- `876316a` Fix startup false offline detection
- `530e077` Fix offline toggle and absorbing empty state
- `f4bf283` Fix absorbing cache stack overflow
- `cced927` Add series-level download action
- `7a4c01d` Improve series download button UX
- `19613dc` Improve series download progress feedback
- `7a522ce` Queue series downloads immediately
- `c1aee30` Improve homelab APK size guidance
- `bda50e0` Fix release download notification failures
- `705e175` Improve tab-targeted refresh behavior
- `31046ca` Improve personalized include loading
- `5310d4c` Clean up API service analyzer warnings
- `f4b0da1` Improve startup refresh targeting
- `54c257b` Improve absorbing-first startup responsiveness

## Grouped workstreams (first-pass triage)

### Group A: Personalized/offline/startup behavior

- `fee7730` Fix personalized refresh overhead
- `876316a` Fix startup false offline detection
- `530e077` Fix offline toggle and absorbing empty state
- `f4bf283` Fix absorbing cache stack overflow
- `705e175` Improve tab-targeted refresh behavior
- `31046ca` Improve personalized include loading
- `5310d4c` Clean up API service analyzer warnings
- `f4b0da1` Improve startup refresh targeting
- `54c257b` Improve absorbing-first startup responsiveness

### Group B: Series download UX flow

- `cced927` Add series-level download action
- `7a4c01d` Improve series download button UX
- `19613dc` Improve series download progress feedback
- `7a522ce` Queue series downloads immediately

### Group C: Download pipeline robustness

- `bda50e0` Fix release download notification failures

### Group D: Homelab identity/side-by-side install

- `47eb5c1` Add homelab side-by-side install support

### Group E: Process/docs-only (non-port default)

- `c1aee30` Improve homelab APK size guidance
- `9841e3d` Add homelab agent continuity docs

## Notes

- Skipped continuity-only commits from the queue; this file is the continuity record for upstream merge work.
- Preferred port order: A -> C -> B -> D; keep E local unless explicitly needed on this branch.
