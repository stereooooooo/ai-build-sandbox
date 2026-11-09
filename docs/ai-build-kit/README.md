# AI build kit (v3.4 reviewed installation copy)

This copy includes two targeted Codex review fixes: task setting values are withheld from
launcher output and stored with owner-only permissions; `resume` reloads the saved settings
and verifies the task database before starting Claude. See INSTALL-REVIEW.md for test results
and rollout limits. The original v3.4 files have not been replaced.

Files that set up the workflow described in *Building Software with AI Agents*: shared agent
instructions, a pull request template, a task launcher, an owner sign-off check, a
review-status helper, and an experimental review-completion check.

What is executable here: `scripts/ai-task.sh` (local), `scripts/pr-review-status.sh` (local),
the `signoff-guard` workflow (GitHub), and the optional review check (GitHub). Everything in
AGENTS.md and CLAUDE.md is instructions: agents follow them while a session runs, and nothing
watches or continues after a session stops.

## Supported scope

- GitHub repositories where pull requests come from **branches in the same repository**.
  Several trusted collaborators can work this way. Pull requests from forks get a failing
  status, not a silent pass. Fork support is a separate capability that has not been tested.
- Merge rules on private repositories need GitHub Pro (personal account) or Team
  (organization). Public repositories get them free.

## Prerequisites

- A Git repository on GitHub with a default branch (the files assume `main`; replace it if
  yours differs) and a working baseline test command.
- `git`, `gh` (signed in), Node and your project's own tools. `jq` for running the tests.
- Claude Code and the Codex CLI, signed in. Codex code review turned on for the repository.

## Files

| File | What it does |
|---|---|
| `AGENTS.md` | Shared rules for every agent: tiers, isolation, the review loop, and the review rules Codex follows on pull requests. Fill in the placeholders. |
| `CLAUDE.md` | Loads AGENTS.md into Claude Code and adds the Claude-only Tier 2 steps. |
| `.github/pull_request_template.md` | What every pull request must state, including which commit the review covered. |
| `.github/workflows/signoff-guard.yml`, `scripts/signoff-guard.sh` | Sets the commit status `owner-signoff` on each pull request's head: success if no sign-off paths changed, or if an owner's `/signoff <commit>` comment approves content identical to the head's. |
| `.github/signoff-paths.txt` | Paths that need owner sign-off. Starts with examples commented out. |
| `scripts/pr-review-status.sh` | Overview of reviews (with the commit each covered), inline threads (open first, all pages) and comments; `--full` prints the complete text with links. |
| `.ai-build/project.env` | Per-project settings for the launcher: default branch, install command, port range, local files to copy, disposable ignored paths, per-task database setup and its verification. |
| `scripts/ai-task.sh` | Task launcher: `start` a fresh worktree and Claude session, `list` tasks, `finish` a task without losing work, `restore` a rescued task. |
| `optional/…/tier2-review-check.*` | **Experimental.** Requires exactly one tier label; for `tier-2`, fails unless the newest non-dismissed Codex review is on the head commit. Do not make it required until the live tests below pass. |
| `tests/run-tests.sh` | Local tests for all scripts (85 scenarios: the reviewed copy's 78 plus 7 added in the sandbox). |

## Task launcher

```
bash scripts/ai-task.sh start <task-name>      # from the project's main checkout
bash scripts/ai-task.sh resume <task-name>     # reload settings before continuing Claude
bash scripts/ai-task.sh list
bash scripts/ai-task.sh finish <task-name>     # --rescue, --allow-open, --drop-db
bash scripts/ai-task.sh restore <rescue-folder> [new-task-name]
```

**start** fetches the default branch, creates `.claude/worktrees/<task>` on `task/<task>`,
copies `COPY_FILES`, picks a port no other task or running program uses, and writes
`.ai-task.env`. If the project has a per-task database it creates it, adds the connection
settings from `DB_ENV_CMD`, and runs `DB_VERIFY_CMD`, which must prove the app's own
configuration resolves to that database, **before** installing anything that could run
migrations. Any failure undoes the start (worktree, branch, and a database it created).
Claude Code starts with `.ai-task.env` loaded, so commands it runs use the task's port and
database. Setting values are withheld from the launcher summary; `.ai-task.env` is mode 600.
Project-specific setup and verification commands must also avoid logging credentials.

**resume** loads `.ai-task.env` in a fresh terminal, checks the configured task database, and
starts `claude --continue` in the task folder. Use it when reopening a session. After restoring
a database task, regenerate its connection settings first; resume refuses an unverified database.

**finish** removes a task only if nothing would be lost. It first fetches with pruning, so a branch deleted on GitHub no longer counts as a copy, and stops if GitHub cannot be reached. It stops, changing nothing, when there
are uncommitted changes, commits not on `origin` (other remotes are not refreshed, so they do not count), gitignored files other than
`DISPOSABLE` paths and unchanged copies of `COPY_FILES`, or a pull request state it cannot
confirm or that is open. Unknown ignored files and local data (such as `.wrangler/state`) are
treated as work.

**finish --rescue** saves first, verifies, then removes: code goes to a pushed
`rescue/<date>-<task>` branch (checked against the remote); other local files are copied to a
private folder outside the repository (`~/.ai-task-rescue/...`, permissions 700, never pushed)
and compared with the originals; a `MANIFEST.txt` records what was saved and how to restore it.
`COPY_FILES` and `.ai-task.env` are never committed to a rescue branch, even if the task changed
`.gitignore`; a changed copy goes to the private folder instead.
Any failure leaves the worktree untouched. **Task databases are kept** unless you pass
`--drop-db`; then a dump is written and checked first if `DB_DUMP_CMD` is set.

**restore** recreates a task from a rescue folder at the exact commit its manifest records: branch, fresh copies of `COPY_FILES` from the main checkout, then the rescued local files on top (verified), a new port. Ports are chosen under a lock, so simultaneous starts or restores never share one.

Written for bash 3.2 (the macOS default). Codex ran the original v3.4 suite (72 passed) and
this reviewed copy (78 passed) under macOS bash 3.2.57; the sandbox fixes bring it to 85. The tests mock GitHub, Claude and
database commands; the live rollout tests below remain necessary.

## How owner sign-off works

1. Review the pull request at a specific commit.
2. Comment on the pull request: `/signoff <commit>` (7 to 40 characters of the commit's ID).
   `/signoff revoke` withdraws it. The latest command from an owner counts. The command is the
   comment's first non-blank line; spaces around it are ignored. An owner's comment that starts
   with `/signoff` but cannot be read (a typo, extra words) counts as a revoke, so it never leaves
   an earlier approval standing.
3. The `owner-signoff` status is green while the sign-off paths in the current head are
   identical to those in the signed-off commit. Any later change to them, in any number of
   pushes, needs a new sign-off. Unrelated changes keep it.

Owners are the logins in the repository variable `SIGNOFF_OWNERS` (comma-separated), or the
repository owner if it is unset. Make the **`owner-signoff` status** the required check, not the
workflow job. To re-run the check, edit a comment or close and reopen the pull request; there is
no manual trigger, because a manual run can use another branch's copy of the workflow.

### What it does and does not guarantee

- It runs the default branch's copy of its workflow and script, and treats the pull request's
  files as data. Its own files and every file under `.github/workflows/` need sign-off to merge.
- Every error while reading GitHub or the repository ends in a failure status (or pending,
  if the head changed during the check), never in success.
- **Other workflows can impersonate it.** Any workflow in the repository with permission to
  write statuses can post an `owner-signoff` status, and the newest status wins. Requiring
  GitHub Actions as the source does not tell workflows apart, and protecting workflow files makes
  such changes visible without stopping a workflow on a pull request branch from posting first.
- **It is not proof of human approval.** A `/signoff` comment shows that someone using an
  owner's login posted it. Agents act through that login too.
- **Revocation is not guaranteed during outages.** If GitHub cannot be reached to post a new
  status, the previous one stays.
- Stronger enforcement needs separate agent and owner identities and an app whose credentials
  editable workflows cannot reach. That is deliberately deferred.

## Trust and state model of signoff-guard

See the header of `scripts/signoff-guard.sh`. Because it runs from the default branch, the guard
does nothing on the pull request that installs it. Install the kit as a Tier 2 change, review it
yourself, merge it, then test it on a throwaway pull request (live tests below).

## Local tests

```
bash tests/run-tests.sh
```

They build throwaway repositories and replace `gh` with a stub, so nothing touches GitHub.
They prove the scripts' logic only. Expected result: all scenarios `ok`, including launcher
runs in a path with spaces, database verification before install, cleanup that refuses
uncommitted, unpushed, post-merge or unknown ignored work, verified rescue and restore,
partial or failed GitHub reads that never produce success, the rapid
push sequence (sign-off, protected push, documentation-only push must stay blocked) and the
`--full` helper output containing findings that sit in a review summary, deep in a comment,
in a reply, and on a second page of threads.

## Live tests (on GitHub and your machine, before relying on the checks)

Local tests cannot show how GitHub events, permissions and required checks behave, what Codex
posts, or whether an application really uses its task database. After the installation pull
request has merged, run these on throwaway pull requests and record the results:

1. **Status appears and can be required.** A throwaway pull request gets an `owner-signoff`
   status on its head commit; the ruleset can require it; the merge box treats it as satisfied
   only when it is green.
2. **Trusted execution.** A pull request that edits `scripts/signoff-guard.sh` to `exit 0` and
   changes a protected path still gets a failing status.
3. **Sign-off cycle.** Protected change fails; `/signoff <head>` passes; a later protected push
   fails; a later unrelated push stays green; `/signoff revoke` fails.
4. **Rapid pushes.** Sign off, then push a protected change and a documentation change within
   seconds. The final head must end up failing.
5. **Two pull requests at once.** A sign-off comment on one does not satisfy the other.
6. **Impersonation (expected to succeed; this documents the limit).** In a sandbox repository
   only, a pull request adding a workflow that posts `owner-signoff: success` can turn the check
   green before sign-off. Record that the trusted guard rejects the unsigned workflow change,
   while the impersonated status can satisfy the same required status. This is a demonstrated
   limit, not a second independently enforced sign-off requirement.
7. **Inline findings.** Codex reports a deliberate bug as an inline thread, merging stays blocked
   until it is resolved, and `pr-review-status.sh --full` shows the full text.
8. **Clean review.** On a change with no issues, record what Codex posts (a review, a comment or
   a reaction), its author login, and which commit it is tied to.
9. **New push after review.** Record whether Codex reviews the new commit on its own, and when.
10. **Experimental gate** (only if 8 shows clean reviews are GitHub reviews tied to a commit):
    set `CODEX_REVIEWER_LOGIN`, then confirm it fails with no tier label, two tier labels, the
    variable unset, a dismissed review, a new push, and rapid label and push events; passes
    once the newest review covers the head; and satisfies a required check.
11. **Task database isolation** (projects with a per-task database): start two tasks, write a
    different fake marker row through each task's running app, and confirm each task sees only
    its own marker and the shared development database has neither. Show connection settings
    only in redacted form.
12. **Fork pull request** (if you can create one): failing status from both checks.
