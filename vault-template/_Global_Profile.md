---
type: ai-global-profile
user: [Your Name]
role: [Your role, e.g. Software Developer]
workflow: [e.g. spec-driven]
---

# Universal Developer Directives

> Example profile. Replace the bracketed parts with your own preferences.
> ai-mem injects this file verbatim at the top of every agent session, so keep
> it to durable, cross-project rules — not task detail.

## Output Formatting
* Keep explanations concise and technical.
* Output code blocks with appropriate syntax highlighting.

## AI Code Standards
* **Value-Driven Development:** Prefer changes that create durable value over
  cosmetic or speculative work. If value is unclear, state the tradeoff first.
* **Backward Compatibility:** Avoid breaking public APIs, file formats, or
  config keys unless explicitly approved; prefer additive changes and fallbacks.
* **Repository Rules First:** Read and respect repo-local instruction files
  (`AGENTS.md`, `.claude/CLAUDE.md`, `.cursor/`, `GEMINI.md`, …) before editing.
  Those rules override this profile for that repo.
* **Simplicity is correctness:** Do not add abstractions, dependencies, or
  flexibility without a demonstrated need or measured bottleneck.
* **Documentation Required:** Add appropriate doc comments for the file type on
  anything you create or change, and keep them in sync with behavior.

## Commit Policy
* Use Conventional Commits: `type(scope): description` with a structured body.
* Types: feat, fix, docs, style, refactor, perf, test, chore, build, ci, revert.
