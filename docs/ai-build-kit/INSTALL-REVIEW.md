# Installation review

Reviewed 7 November 2026. Verdict: ready for staged installation using this reviewed copy.
Install in a sandbox first and complete the guide's live checks before relying on enforcement.
Then use one lower-risk project. Install in software used by clinic staff after its separate
deployment and seed-script prerequisites are completed.

The submitted v3.4 kit passed all 72 supplied tests under macOS bash 3.2.57. Six independently
rerun regression scenarios also passed: partial comments, failed head lookup, failed PR-details
lookup, ignored-file cleanup refusal, private rescue of ignored files, and failed PR lookup
during cleanup. Their fixtures were adapted to v3.4's fetched-head ref, PR-list API and private
rescue directory; no production repositories or services were used.

Two final issues were reproduced in v3.4 and corrected in this copy:

1. The launcher indented settings before applying an anchored redaction pattern. Plain
   password/token variables consequently appeared in its output. The summary now withholds
   all setting values, and newly created/restored task settings use permissions 600.
   Project-specific commands remain responsible for avoiding sensitive output.
2. The guide's bare `claude --continue` command did not load `.ai-task.env` in a new terminal.
   The new `resume` command loads those settings and requires successful database verification
   when a task database is present, before starting Claude. Use:

   ```bash
   bash scripts/ai-task.sh resume <task-name>
   ```

The reviewed copy passed 78 supplied/extended scenarios and the same six independent
regression scenarios. Tests use simulated GitHub responses, Claude and database commands.
They do not prove live GitHub permissions, merge eligibility, Codex review events, cmux
session behavior or the database connection chosen by a real application.

Changes are limited to `scripts/ai-task.sh`, its tests, README and agent instructions, plus
this note. The accompanying reviewed guide/checklist correct the resume instructions and
test counts. The sandbox impersonation test wording now clearly states that a spoofed status
can satisfy the same required check; workflow-path protection is not a second independent gate.
The sign-off implementation and optional review gate were not changed by this review.

Before relying on the installed system:

- Configure the project commands, disposable paths, database verification and sign-off owners.
- Prove the required status blocks and unblocks merges on sandbox PRs, including revocation
  and rapid pushes. Record the documented status-impersonation limitation.
- Observe what Codex posts for clean and finding-producing reviews and after another push.
  Leave `tier2-review-check` uninstalled until its live behavior is established.
- Exercise a real start/resume/review/cleanup cycle on the lower-risk project. For task
  databases, prove isolation through the two running applications using synthetic markers.
- Keep owner sign-off, merge and release decisions human-controlled. The kit does not prove
  independent human approval when agents share the owner's credentials.

No existing project, GitHub setting, cmux configuration, skill installation or deployment was
changed by this review. The source downloads remain intact. The included test log records the
78-scenario run; the independent regression summary is included alongside it.
