# Migration Diagram

This diagram shows the full legacy-to-story-task migration flow, including install-time upgrade, sprint container migration, placeholder creation, and all post-migration recovery paths.

```mermaid
flowchart TD
    A[Legacy repo or upgraded repo] --> B{install.sh upgrade?}

    B -->|No| C[Manual migration entrypoint<br/>./scripts/ralph/ralph-sprint-migrate.sh]
    B -->|Yes| D{Legacy epics.json sprints detected?}

    D -->|No| E[Install current framework only]
    D -->|Yes, migrate enabled| F[Run ralph-sprint-migrate.sh for each legacy sprint]
    D -->|Yes, migrate disabled| G[Leave repo in guided/manual migration state]

    C --> F

    F --> H[Read epics.json]
    H --> I[Map EPIC-XXX to S-XXX<br/>dependsOn to depends_on<br/>create stories.json entries]

    I --> J{Per-epic task data source?}

    J -->|Matching live prd.json| K[Recover tasks from live prd.json]
    J -->|Archived per-epic prd.json| L[Recover tasks from archived prd.json]
    J -->|No recoverable prd.json,<br/>but PRD markdown exists| M[Create placeholder story.json]
    J -->|No prd.json and no markdown| N[Create manual-recovery placeholder]

    K --> O[story.json with tasks_recovered=true]
    L --> O

    M --> P[story.json with tasks_recovered=false<br/>status becomes blocked for runnable stories]
    N --> P

    O --> Q{Story valid after migration?}
    P --> Q

    Q -->|Recovered task data| R[Story keeps effective migrated status]
    Q -->|Placeholder only| S[Story remains blocked<br/>or historical done/abandoned]

    R --> T[stories.json written]
    S --> T

    T --> U{Need post-migration placeholder recovery?}
    U -->|No| V[Normal framework flow<br/>specify / prepare / run / commit]
    U -->|Yes| W[./scripts/ralph/ralph-story.sh generate S-XXX --force]

    W --> X{Recovery path}

    X -->|1. Deterministic markdown parse succeeds| Y[Direct markdown -> story.json]
    X -->|2. Deterministic parse fails,<br/>markdown still available| Z[Try temporary prd.json bridge]
    X -->|3. No markdown or bridge fails| AA[Final guided direct story.json fallback]

    Z --> AB{Temporary prd.json bridge succeeds?}
    AB -->|Yes| AC[Markdown -> temporary prd.json -> local story.json conversion]
    AB -->|No| AA

    Y --> AD[migration.source=legacy-prd-markdown]
    AC --> AE[migration.source=legacy-prd-json-bridge]
    AA --> AF[migration.source=legacy-placeholder-guided-recovery]

    AD --> AG[Reset blocked story to planned]
    AE --> AG
    AF --> AG

    AG --> AH{Next path}
    AH -->|prepare-all / generate-all --force| AI[Health check -> promote to ready]
    AH -->|manual flow| AJ[Run health or specify next]

    AI --> AK[Normal execution loop]
    AJ --> AK

    subgraph "SpecKit relationship"
        SL1[prd.json import path] --> SL2[ralph-story.sh import-prd]
        SL2 --> SL3[stories.json backlog entries]
        SL3 --> SL4[ralph-story.sh specify]
        SL4 --> SL5[.specify/spec.md plan.md tasks.md]
        SL5 --> SL6[ralph-story.sh generate -> story.json]
    end

    subgraph "Migration recovery notes"
        MN1[Deterministic path does not invoke Codex]
        MN2[Temporary prd.json bridge is model-assisted but structured]
        MN3[Final guided fallback is last-resort and explicitly annotated]
        MN4[Placeholder recoveries run serially in generate-all --force]
    end
```

## Reading Guide

- `ralph-sprint-migrate.sh` handles sprint container migration and first-pass task recovery.
- `ralph-story.sh generate --force` handles placeholder repair after migration.
- `SpecKit` is part of the normal modern story preparation flow, not the core legacy migration pipeline.
- The temporary `prd.json` bridge is only used as an intermediate recovery step for legacy markdown when deterministic parsing is not enough.
