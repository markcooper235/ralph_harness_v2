# Recovery And Advanced Helpers

Use these helpers only when the current task actually needs them:

- `ralph-story.sh add` for non-interactive story creation
- `ralph-story.sh set-status` to reset a stuck story
- `ralph-story.sh import-prd` to import an existing `prd.json`
- `ralph-sprint-migrate.sh` for legacy epic/PRD sprint migration
- `ralph-cleanup.sh --force` to clear stale workflow locks and transient state

Health/prep helpers:

- `ralph-story.sh health` validates task count, shell-check syntax, context completeness, dependency integrity, and duplicate detection
- `ralph-story.sh prep-status [--details] [--story ID]` inspects the latest prep journal without opening raw JSON

Open `docs/maintainer-notes.md` when:

- migration behavior is involved
- roadmap policy matters
- scope enforcement or smoke harness behavior is unclear
- this recovery reference is not enough
