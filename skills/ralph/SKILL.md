---
name: ralph
description: "Convert PRDs to prd.json format for import into a Ralph sprint. Use when you have an existing PRD and need to convert it to Ralph's JSON format. Triggers on: convert this prd, turn this into ralph format, create prd.json from this, ralph json."
---

# Ralph PRD Converter

Convert a PRD (markdown or text) into `prd.json` for import into a Ralph sprint via `ralph-story.sh import-prd`.

## Non-Negotiables

- Keep each story completable in one focused session (one context window).
- Order stories by dependency (schema -> backend -> UI -> aggregate views).
- Require verifiable acceptance criteria only.
- Include `Typecheck passes` in every story.
- Add browser verification criteria for UI stories.
- Set every story to `passes: false` and `notes: ""` initially.

## The Job

- Read source PRD content.
- Create/update `prd.json` in the Ralph directory.
- Preserve intent, split oversized work, and enforce verifiable criteria.
- After writing prd.json, the caller runs `ralph-story.sh import-prd` to load it into the active sprint backlog.

## Required `prd.json` Shape

```json
{
  "project": "[Project Name]",
  "branchName": "ralph/[feature-name-kebab-case]",
  "description": "[Feature summary]",
  "userStories": [
    {
      "id": "US-001",
      "title": "[Story title]",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": ["Criterion", "Typecheck passes"],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

## Core Rules

### 1) Story size (most important)

Each story must be completable in one focused session.

- Good: one migration, one backend action, one UI component, one filter control.
- Too large: "build dashboard", "add full auth", "refactor API".
- Rule of thumb: if a story needs more than 2-3 sentences to describe, split it.

### 2) Dependency order

Order by prerequisites:

1. Schema/database
2. Backend/server logic
3. UI consuming backend
4. Aggregate/dashboard views

No story may depend on a later story.

### 3) Verifiable acceptance criteria

Use checkable outcomes only.

- Good: "Add `status` column with default 'pending'"
- Bad: "Works correctly"

Always include:

- `Typecheck passes`

Include when applicable:

- `Tests pass` (for testable logic)
- `Verify in browser using dev-browser skill` (for UI changes)

## Conversion Rules

1. Each user story becomes one JSON `userStories` entry.
2. IDs are sequential (`US-001`, `US-002`, ...).
3. Priority follows dependency order, then source PRD order.
4. Every story starts with `passes: false` and `notes: ""`.
5. `branchName` is `ralph/<feature-kebab-case>`.
6. Ensure all stories include `Typecheck passes`.

## Splitting Guidance

If the PRD says "Add notification system", split into focused stories such as:

1. Add notifications table
2. Add notification service
3. Add bell icon in header
4. Add dropdown panel
5. Add mark-as-read action
6. Add preferences page

## After Writing prd.json

Import into the active sprint and run story preparation:

```bash
./scripts/ralph/ralph-story.sh import-prd scripts/ralph/prd.json
./scripts/ralph/ralph-story.sh prepare-all
./scripts/ralph/ralph.sh
```

## Final Checklist

- [ ] Stories are one-session size
- [ ] Dependency order is valid
- [ ] Every story includes `Typecheck passes`
- [ ] UI stories include browser verification
- [ ] Criteria are verifiable and specific
