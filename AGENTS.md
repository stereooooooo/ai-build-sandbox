# AGENTS.md: ai-build-sandbox

Shared instructions for every coding agent. Codex reads this file directly. Claude Code reads it through CLAUDE.md (`@AGENTS.md`). Keep one copy of each rule here. If the default branch is not `main`, replace `main` throughout.

## Project

- What it is and who uses it: a throwaway repository for live tests of the AI build kit; nobody uses the demo app.
- Owner (the human who decides, merges and releases): stereooooooo
- Live users: none
- Stack: Node (built-in `node:http` and `node:test`), no database, not hosted
- Sensitive data: none. This repository is public. No agent session may connect to production, copy production data, or read production credentials. Use synthetic data only. Never put real personal data in the repository, test fixtures, screenshots or logs.

## Commands

- Install: `npm ci`
- Dev server: `PORT=$PORT npm run dev`
- Lint, types, unit tests: `npm test` (no lint or type check)
- Database tests (disposable local database only): none (no database)
- Release: owner only. Nothing deploys.

## Working rules

1. Start every session by reporting `pwd`, `git branch --show-current` and `git status --short`. If anything is unexpected, stop and say so.
2. Work only in your own worktree. Never edit the main checkout, never touch another worktree, and never switch branches in a worktree that has uncommitted changes.
3. One task per branch, branched from current `origin/main`, pushed to this repository (not a fork). Never add new work to a branch whose pull request has merged. Start a new branch.
4. State the risk tier (below) before you begin. If unsure, use the higher tier.
5. Keep changes small. No unrelated refactors, dependency upgrades or cleanup in the same branch.
6. Commit at coherent checkpoints. Push and open a pull request that fills in the PR template. Apply exactly one label: `tier-0`, `tier-1` or `tier-2`.
7. Never merge, release, change repository settings, post a `/signoff` comment, resolve Tier 2 review threads, or run anything against production. Those are the owner's actions.
8. Never weaken a test, check, CI job or deploy script to make something pass.
9. A worktree isolates files only. If the task was started with `scripts/ai-task.sh`, your session already has this task's `.ai-task.env` loaded: `PORT`, `AI_TASK_DB` and any connection settings the project adds. Use them and nothing else; if a command would use a different database, stop and say so. Otherwise use a dev-server port and local database name no other worktree uses. Never run migrations or schema pushes against a database another worktree uses, and never against production.
10. These instructions only apply while a session is running. Nothing here keeps working after you stop: if you end with a pull request still waiting on checks or review, say so in your report.
11. Reopen a launcher-created task with `bash scripts/ai-task.sh resume <task-name>` from the project folder. It reloads saved settings and verifies the task database before continuing Claude. A bare `claude --continue` in a fresh terminal does not reload those settings. After a restore, regenerate missing connection settings before resuming.

## Risk tiers

- **Tier 0**: copy, styling, documentation, adding a new test, tooling with no runtime effect.
- **Tier 1**: normal product behavior that does not change stored data, schema, permissions, money, or safety-relevant logic.
- **Tier 2**: database writes, schema or migrations, seed or data scripts that run in production, authentication or permissions, payments, personal data, clinical or other safety-relevant logic, concurrency, deployment, and anything that changes which tests run, how checks are enforced, or how CI behaves (including installing or editing this kit).

## Review loop after opening a pull request

Use `bash scripts/pr-review-status.sh <n>` for an overview and `bash scripts/pr-review-status.sh <n> --full` for the complete text. Read `--full` before acting on findings: they can sit in a review summary, deep in a comment, or in a reply. If `--full` says a thread has more replies than it shows, open that thread's link and read them. `gh pr view --comments` misses inline review comments entirely.

1. Wait for checks: `gh pr checks <n> --watch`.
2. Wait for the Codex review to finish, and identify which commit it covered. Only a GitHub review shows its commit; the status script marks a review of the current head with `(head)`. A comment without a review record does not prove which commit was reviewed, even if it appeared after your push: report it as unverified. If nothing appears within 15 minutes, comment `@codex review` once and wait again. Never report a pull request as ready while the review is unfinished or unverified; say which.
3. For each Codex finding, either fix it or reply with evidence (a reproducer or a test) showing why it does not apply. Reply on the thread with the fixing commit SHA.
4. Tier 0 and Tier 1: one review pass. After fixing its findings you do not need a new review unless a fix changed logic beyond the finding; say which commits came after the reviewed one. You may resolve a thread after replying with the fix SHA or evidence.
5. Tier 2: after the last fix, comment `@codex review` and confirm with the status script that the newest Codex review is marked `(head)`. Leave Tier 2 threads for the owner to resolve. Stop after 3 review rounds and summarize any disagreement for the owner.
6. Add the `codex-caught` label if a Codex finding led to a code change.
7. Report to the owner: what changed, the tier, checks that ran and any that were skipped, which commit the Codex review covered (or that it is unfinished or unverified) and any commits after it, each finding and how it was resolved, and anything that needs a decision.

## Testing

- Test layers and where they live: unit only, `test/*.test.js` (`node:test`)
- Agreed places to test (so the tdd skill does not need to ask each time): pure functions in `src/`
- Adding a test is Tier 0. Changing which tests run, their enforcement, or CI is Tier 2.

## Skills

Use an installed skill only in the situations below, and name it in your report. If it is not installed for you, do the same work without it. Skills never change tiers, sign-off, or what GitHub requires before merging.

| Situation | Skill, if installed | Expected result |
|---|---|---|
| A substantial feature is still vague | `grill-with-docs` (or `grilling` with `domain-modeling`) | Agreed behavior, acceptance examples and shared terms. Ask only questions that change what gets built. |
| A bug or a performance regression | `diagnosing-bugs` | A reproducible failure or measurement first, then the fix and a regression test |
| New behavior or a bug fix that a test can protect | `tdd` | A test that fails for the real problem, then passes. Use the layers under Testing. |
| The owner asks why the code is hard to change | `improve-codebase-architecture` / `codebase-design` | Ranked candidates; the chosen one becomes its own task |
| Web interface work | Impeccable `critique` or `audit`, then one scoped pass (`clarify`, `adapt`, `harden` or `polish`) | A clearer journey, checked in a browser, following the priorities below |
| Optional self-check before a substantial pull request | `code-review` | A check against the task. It does not replace the Codex review on GitHub and does not count as the review being finished. |

- Interface priorities for this project: none (no interface)
- Design context: none yet

## Code Review Rules

(Read by Codex code review on pull requests.)

- Report only issues that cause incorrect behavior, data loss or exposure, broken permissions, failed or unsafe migrations, money errors, or unsafe output to users. Do not comment on style or naming.
- For each finding give the location, the scenario that triggers it, and the impact. Say whether you observed it or suspect it.
- Treat as P0: data visible to the wrong user; one user's edit silently overwriting another's; a migration or data script that changes or deletes live data without that being the stated, reviewed purpose of the change, or without preconditions and a safe rerun; a required test suite that is skipped or excluded but still reports success.
- Project-specific P0s: a change to `src/rules/` that alters the discount without owner sign-off
- Flag new behavior that has no test, including failure paths (unauthorized user, stale form, duplicate submit, timeout).
