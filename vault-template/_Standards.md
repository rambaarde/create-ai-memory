---
type: ai-standards
scope: global
status: active
mirror_of: _Global_Profile.md
---

# Shared Standards

> Example standards note. ai-mem injects this after the profile on every
> session. Use it for extra shared rules you want visible in every agent run.
> If a repo-local instruction conflicts with this note, the repo-local wins.

## Engineering
* **SOLID by default:** small, cohesive modules with explicit dependencies.
* **Composition over inheritance:** prefer delegation and interfaces.
* **Safe evolution:** prefer feature flags and compatibility shims over
  rewrites; isolate behavior-changing refactors and call out the risk.
* **Quality bar:** keep tests, types, linting, and docs aligned with the change.
  If a standard cannot be met this turn, say so explicitly.

## Memory Continuity
* Load the current project note plus the latest prior session log for the active
  project. Do not load full session history unless asked.
* Keep durable preferences and project facts in the vault; keep run-specific
  decisions, blockers, and next steps in the session log.

## Standards Addendum
* Keep this note and `_Global_Profile.md` in lockstep when shared rules change.
