#!/usr/bin/env bash
# Local tests for the kit's scripts. Needs bash, git and jq. Makes throwaway repositories in a
# temp folder and replaces the GitHub CLI with a stub, so nothing touches GitHub.
#
# These are LOCAL tests: they prove the scripts' logic against a simulated GitHub. They do
# not prove how GitHub events, permissions, required checks or Codex behave. README.md lists
# the live tests for that.
#
# Usage: bash tests/run-tests.sh
set -uo pipefail

# The kit root is the repository holding this file, so the suite also runs from tests/ai-build-kit/.
KIT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STUB="$WORK/bin"; FIX="$WORK/fix"
mkdir -p "$STUB" "$FIX"
export PATH="$STUB:$PATH" GIT_CONFIG_GLOBAL="$WORK/gitconfig" FIX GH_LOG="$WORK/gh.log"
git config --global user.email test@example.com
git config --global user.name test
git config --global init.defaultBranch main

# ---- GitHub CLI stub -------------------------------------------------------------------
# Serves fixtures from $FIX, records status posts in $GH_LOG, and applies --jq with real jq
# one page at a time, as gh does with --paginate.
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
# STUB_MODE simulates GitHub failures: head-error, cross-error, partial-comments, post-error.
# STUB_PR_FAIL=1 makes pull request lookups fail (e.g. HTTP 503).
args="$*"; expr=""; prev=""; head_branch=""
for a in "$@"; do
  [ "$prev" = "--jq" ] && expr="$a"; [ "$prev" = "--head" ] && head_branch="$a"; prev="$a"
done
apply() { if [ -n "$expr" ]; then jq -c '.' "$1" | while IFS= read -r page; do printf '%s\n' "$page" | jq -r "$expr"; done; else cat "$1"; fi; }
case "$args" in
  "repo view"*) echo "o/r" ;;
  "pr list"*)
    [ "${STUB_PR_FAIL:-}" = 1 ] && { echo "HTTP 503: service unavailable" >&2; exit 1; }
    f="$FIX/prlist-$(printf '%s' "$head_branch" | tr '/' '_').json"
    [ -f "$f" ] || { echo "[]" > "$FIX/empty.json"; f="$FIX/empty.json"; }
    apply "$f" ;;
  "pr view"*labels*) apply "$FIX/prinfo.json" ;;
  "pr view"*isCrossRepository*)
    [ "${STUB_MODE:-}" = cross-error ] && { echo "HTTP 503" >&2; exit 1; }
    cat "$FIX/cross.txt" 2>/dev/null || echo false ;;
  "pr view"*headRefOid*)
    [ "${STUB_MODE:-}" = head-error ] && { echo "HTTP 503" >&2; exit 1; }
    cat "$FIX/head.txt" ;;
  *"-X POST"*statuses*)
    [ "${STUB_MODE:-}" = post-error ] && { echo "HTTP 503" >&2; exit 1; }
    echo "$args" >> "$GH_LOG" ;;
  *graphql*)
    cur="first"; for a in "$@"; do case "$a" in after=*) cur="${a#after=}" ;; esac; done
    apply "$FIX/graphql-$cur.json" ;;
  *"/pulls/"*"/reviews"*) apply "$FIX/reviews.json" ;;
  *"/issues/"*"/comments"*)
    apply "$FIX/comments.json"
    [ "${STUB_MODE:-}" = partial-comments ] && { echo "HTTP 503 on page 2" >&2; exit 1; }
    true ;;
  *) echo "stub gh: unexpected call: $args" >&2; exit 2 ;;
esac
EOF
chmod +x "$STUB/gh"

pass=0; fail=0
check() { # name expected actual [extra-condition-result]
  local name="$1" want="$2" got="$3" extra="${4:-ok}"
  if [ "$want" = "$got" ] && [ "$extra" = "ok" ]; then
    pass=$((pass + 1)); printf '  ok    %s\n' "$name"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s (expected %s, got %s%s)\n' "$name" "$want" "$got" "$([ "$extra" = ok ] || echo "; $extra")"
    sed 's/^/        | /' "$WORK/out.txt"
  fi
}

# ---- signoff-guard ---------------------------------------------------------------------
# A repository whose main branch holds the trusted policy, plus a worktree for the pull
# request's commits. The guard runs from the main checkout, as the workflow does.
new_repo() { # $1 = exact contents of .github/signoff-paths.txt on main
  R="$WORK/repo$RANDOM$RANDOM"; mkdir -p "$R"; cd "$R" || exit 1
  git init -q
  mkdir -p .github/workflows scripts src/rules src/ui docs
  printf '%b' "$1" > .github/signoff-paths.txt
  cp "$KIT/scripts/signoff-guard.sh" scripts/
  cp "$KIT/.github/workflows/signoff-guard.yml" .github/workflows/
  echo rule > src/rules/r.ts; echo ui > src/ui/a.ts; echo doc > docs/d.md
  git add -A; git commit -qm base
  MAIN=$(git rev-parse HEAD)
  git worktree add -q "$R-pr" -b feat
  : > "$FIX/comments.json"; echo "[]" > "$FIX/comments.json"
  echo false > "$FIX/cross.txt"
  cd "$R" || exit 1
}
pr_commit() { # $1 = shell command run in the PR worktree; prints the new head
  (cd "$R-pr" && eval "$1" && git add -A && git commit -qm change) >/dev/null
  git -C "$R-pr" rev-parse HEAD
}
comments() { # login|time|body ... (body may contain \n)
  local out="[" sep=""
  for c in "$@"; do
    IFS='|' read -r who when body <<< "$c"
    out="$out$sep$(jq -cn --arg u "$who" --arg t "$when" --arg b "$(printf '%b' "$body")" \
      '{user: {login: $u}, updated_at: $t, created_at: $t, body: $b}')"; sep=","
  done
  echo "$out]" > "$FIX/comments.json"
}
guard() { # LIVE_HEAD [FETCHED_HEAD] -> final status state (success|pending|failure|none|error)
  echo "$1" > "$FIX/head.txt"; : > "$GH_LOG"
  git -C "$R" update-ref refs/remotes/origin/pr-head "${2:-$1}"
  ( cd "$R" && PR_NUMBER=7 GH_REPO=o/r BASE_REF="${GUARD_BASE:-main}" OWNERS="ray,partner" \
      bash scripts/signoff-guard.sh ) > "$WORK/out.txt" 2>&1 || { echo "error"; return; }
  last="$(tail -n 1 "$GH_LOG")"
  case "$last" in *state=success*) echo success ;; *state=pending*) echo pending ;; *state=failure*) echo failure ;; *) echo none ;; esac
}
on_head() { tail -n 1 "$GH_LOG" | grep -q "statuses/$1 " && echo ok || echo "final status not posted on ${1:0:7}"; }
never_success() { grep -q "state=success" "$GH_LOG" && echo "a success status was posted" || echo ok; }

echo "signoff-guard"
new_repo 'src/rules/**\n'
H=$(pr_commit 'echo x >> src/ui/a.ts')
r=$(guard "$H"); check "no sign-off paths changed: success" success "$r" "$(on_head "$H")"

new_repo 'src/rules/**\n'
A0=$(pr_commit 'echo x >> src/rules/r.ts')
r=$(guard "$A0"); check "protected change without sign-off: failure" failure "$r"
comments "ray|2026-01-01T10:00:00Z|/signoff ${A0:0:7}"
r=$(guard "$A0"); check "owner signs off the current commit: success" success "$r"
A=$(pr_commit 'echo y >> src/rules/r.ts')
B=$(pr_commit 'echo z >> docs/d.md')
r=$(guard "$B"); check "rapid pushes (protected, then docs only) stay blocked (regression)" failure "$r" "$(on_head "$B")"
r=$(guard "$A"); check "the intermediate protected push is blocked too" failure "$r"
comments "ray|2026-01-01T10:00:00Z|/signoff ${A0:0:7}" "ray|2026-01-01T11:00:00Z|/signoff $B"
r=$(guard "$B"); check "new sign-off on the latest commit: success" success "$r"
C=$(pr_commit 'echo w >> src/ui/a.ts')
r=$(guard "$C"); check "later unprotected change keeps the sign-off" success "$r"
comments "ray|2026-01-01T10:00:00Z|/signoff $B" "ray|2026-01-01T12:00:00Z|/signoff revoke"
r=$(guard "$C"); check "revoke removes the sign-off" failure "$r"
comments "agent-bot|2026-01-01T10:00:00Z|/signoff $C"
r=$(guard "$C"); check "sign-off from someone not listed as an owner is ignored" failure "$r"
comments "partner|2026-01-01T10:00:00Z|/signoff ${C:0:10}  \r\nLooks right."
r=$(guard "$C"); check "second listed owner, trailing spaces and extra lines accepted" success "$r"
comments "ray|2026-01-01T10:00:00Z|I will /signoff $C later"
r=$(guard "$C"); check "a mention that is not a command does not count" failure "$r"
comments "ray|2026-01-01T10:00:00Z|/signoff $MAIN"
r=$(guard "$C"); check "sign-off on a commit without the change fails" failure "$r"
comments "ray|2026-01-01T10:00:00Z|/signoff deadbeef1"
r=$(guard "$C"); check "sign-off naming an unknown commit fails" failure "$r"
OTHER=$(cd "$R" && git commit -q --allow-empty -m other && git rev-parse HEAD)
comments "ray|2026-01-01T10:00:00Z|/signoff $OTHER"
r=$(guard "$C"); check "sign-off on a commit outside this pull request fails" failure "$r"

new_repo 'src/rules/**'
H=$(pr_commit 'echo x >> src/rules/r.ts')
r=$(guard "$H"); check "path list without final newline still protects" failure "$r"

new_repo 'src/rules/**\r\n'
H=$(pr_commit 'echo x >> src/rules/r.ts')
r=$(guard "$H"); check "path list with Windows line endings still protects" failure "$r"

new_repo 'src/rules/**\n'
H=$(pr_commit ': > .github/signoff-paths.txt; echo x >> src/rules/r.ts')
r=$(guard "$H"); check "PR that empties the path list cannot bypass" failure "$r"

new_repo ''
H=$(pr_commit 'echo "# edit" >> scripts/signoff-guard.sh')
r=$(guard "$H"); check "PR that edits the guard script needs sign-off" failure "$r"

new_repo ''
H=$(pr_commit 'echo "exit 0" > scripts/tier2-review-check.sh')
r=$(guard "$H"); check "PR that adds the optional review gate needs sign-off" failure "$r"

new_repo 'src/rules/**\n'
H=$(pr_commit 'echo x >> src/ui/a.ts')
echo true > "$FIX/cross.txt"
r=$(guard "$H"); check "fork pull request: failure status, not a pass" failure "$r"
echo false > "$FIX/cross.txt"
r=$(guard 1111111111111111111111111111111111111111 "$H"); check "head changed during the check: pending on the new head, never success" pending "$r" "$(on_head 1111111111111111111111111111111111111111)"

echo "signoff-guard failure handling (v3.4 regressions)"
new_repo 'src/rules/**\n'
H=$(pr_commit 'echo x >> src/rules/r.ts')
comments "ray|2026-01-01T10:00:00Z|/signoff $H"
r=$(STUB_MODE=partial-comments guard "$H"); check "comments read fails after an approval on page 1: failure, never success" failure "$r" "$(never_success)"
r=$(STUB_MODE=head-error guard "$H"); x=$(on_head "$H"); [ "$x" = ok ] && { tail -n 1 "$GH_LOG" | grep -q "statuses/$MAIN " && x="posted on the default branch commit"; }
check "head lookup fails: failure posted on the fetched pull request head" failure "$r" "$x"
r=$(STUB_MODE=cross-error guard "$H"); x=ok; tail -n 1 "$GH_LOG" | grep -q "Could not read" || x="wrong reason given"
check "pull request details unreadable: failure with the real reason" failure "$r" "$x"
r=$(GUARD_BASE=no-such-branch guard "$H"); check "unexpected git error: failure, not a stale status" failure "$r" "$(never_success)"
r=$(STUB_MODE=post-error guard "$H"); check "status cannot be posted: the run fails visibly" error "$r"
: > "$GH_LOG"; git -C "$R" update-ref -d refs/remotes/origin/pr-head; echo "$H" > "$FIX/head.txt"
( cd "$R" && PR_NUMBER=7 GH_REPO=o/r BASE_REF=main OWNERS=ray bash scripts/signoff-guard.sh ) > "$WORK/out.txt" 2>&1 && r=PASS || r=FAIL
x=ok; [ -s "$GH_LOG" ] && x="posted a status without a fetched head"
check "pull request head not fetched: run fails and posts nothing (documented limit)" FAIL "$r" "$x"
r=$(guard "$H"); check "after the failures, a normal run still succeeds" success "$r"

new_repo ''
H=$(pr_commit 'mkdir -p .github/workflows && echo "on: push" > .github/workflows/other.yml')
r=$(guard "$H"); check "a pull request adding any workflow needs sign-off" failure "$r"

# ---- tier2-review-check (experimental) ------------------------------------------------
HEADSHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # also used by the pr-review-status tests
OLDSHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
echo "tier2-review-check (experimental)"
if [ ! -f "$KIT/optional/scripts/tier2-review-check.sh" ]; then
  printf '  skip  optional tier2-review-check is not installed here\n'
else
rev() { printf '{"id":%s,"user":{"login":"%s"},"state":"%s","commit_id":"%s","submitted_at":"%s","body":"%s","html_url":"https://x/r%s"}' "$RANDOM" "$1" "$2" "$3" "$4" "${5:-}" "$RANDOM"; }
prinfo() { # labels-json cross
  printf '{"headRefOid":"%s","isCrossRepository":%s,"labels":%s}\n' "$HEADSHA" "${2:-false}" "$1" > "$FIX/prinfo.json"
}
t2() { # reviewer-login
  ( GH_REPO=o/r PR_NUMBER=5 REVIEWER_LOGIN="$1" bash "$KIT/optional/scripts/tier2-review-check.sh" ) \
    > "$WORK/out.txt" 2>&1 && echo PASS || echo FAIL
}
C=codex-bot
{ echo "[$(rev $C COMMENTED $OLDSHA 2026-01-01T00:00:00Z)]"
  echo "[$(rev ray COMMENTED $HEADSHA 2026-01-02T00:00:00Z)]"
  echo "[$(rev $C COMMENTED $HEADSHA 2026-01-03T00:00:00Z)]"; } > "$FIX/reviews.json"
prinfo '[]';                                         r=$(t2 $C); check "no tier label fails" FAIL "$r"
prinfo '[{"name":"tier-1"},{"name":"tier-2"}]';      r=$(t2 $C); check "two tier labels fail" FAIL "$r"
prinfo '[{"name":"tier-1"},{"name":"bug"}]';         r=$(t2 $C); check "tier-1 passes without a review gate" PASS "$r"
prinfo '[{"name":"tier-2"}]';                        r=$(t2 ""); check "missing reviewer setting fails closed" FAIL "$r"
prinfo '[{"name":"tier-2"}]';                        r=$(t2 $C); check "newest review on the live head passes (paginated)" PASS "$r"
prinfo '[{"name":"tier-2"}]' true;                   r=$(t2 $C); check "fork pull request is blocked" FAIL "$r"
prinfo '[{"name":"tier-2"}]'
echo "[$(rev $C COMMENTED $OLDSHA 2026-01-01T00:00:00Z),$(rev ray APPROVED $HEADSHA 2026-01-02T00:00:00Z)]" > "$FIX/reviews.json"
r=$(t2 $C); check "Codex review on an older commit fails" FAIL "$r"
echo "[$(rev $C COMMENTED $OLDSHA 2026-01-01T00:00:00Z),$(rev $C DISMISSED $HEADSHA 2026-01-02T00:00:00Z)]" > "$FIX/reviews.json"
r=$(t2 $C); check "dismissed review on head does not count" FAIL "$r"
echo "[]" > "$FIX/reviews.json"
r=$(t2 $C); check "no reviews fails" FAIL "$r"
echo "[$(rev $C COMMENTED $HEADSHA 2026-01-05T00:00:00Z),$(rev $C COMMENTED $OLDSHA 2026-01-01T00:00:00Z)]" > "$FIX/reviews.json"
r=$(t2 $C); check "reviews out of order are sorted by time" PASS "$r"
fi

# ---- pr-review-status -------------------------------------------------------------------
echo "pr-review-status"
echo "$HEADSHA" > "$FIX/head.txt"
jq -cn --arg h "$HEADSHA" --arg o "$OLDSHA" '[
  {id:1, user:{login:"codex-bot"}, state:"COMMENTED", commit_id:$o, submitted_at:"2026-01-01T00:00:00Z", html_url:"https://x/review1", body:""},
  {id:2, user:{login:"codex-bot"}, state:"COMMENTED", commit_id:$h, submitted_at:"2026-01-02T00:00:00Z", html_url:"https://x/review2",
   body:"Reviewed the change.\n\nP1: SUMMARY-ONLY FINDING about retry handling."}]' > "$FIX/reviews.json"
thread() { # id resolved path line totalCount comments-json
  jq -cn --arg id "$1" --argjson r "$2" --arg p "$3" --argjson l "$4" --argjson tc "$5" --argjson c "$6" \
    '{id:$id, isResolved:$r, isOutdated:false, path:$p, line:$l, comments:{totalCount:$tc, nodes:$c}}'
}
cm() { jq -cn --arg a "$1" --arg b "$(printf '%b' "$2")" --arg u "$3" '{author:{login:$a}, body:$b, url:$u, createdAt:"2026-01-02T00:00:00Z"}'; }
page() { # hasNext cursor threads...
  local hn="$1" cur="$2"; shift 2
  local nodes; nodes="$(printf '%s\n' "$@" | jq -cs '.')"
  jq -cn --argjson hn "$hn" --arg cur "$cur" --argjson nodes "$nodes" \
    '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:$hn, endCursor:$cur}, nodes:$nodes}}}}}'
}
page true CUR1 \
  "$(thread T1 true src/a.ts 3 1 "[$(cm codex-bot 'Old finding' https://x/c1)]")" \
  "$(thread T2 false src/b.ts 9 3 "[$(cm codex-bot 'P1 Stale form overwrites\nMULTILINE-EXPLANATION: a second save wins.' https://x/c2),$(cm ray 'REPLY-TEXT from the builder' https://x/c3)]")" \
  > "$FIX/graphql-first.json"
page false "" \
  "$(thread T3 false src/c.ts 4 1 "[$(cm codex-bot 'SECOND-PAGE-FINDING on permissions' https://x/c4)]")" \
  > "$FIX/graphql-CUR1.json"
echo '[{"user":{"login":"codex-bot"},"created_at":"2026-01-02T00:00:00Z","html_url":"https://x/ic1","body":"Summary line\nBURIED-FINDING: the export skips archived cases."}]' > "$FIX/comments.json"

( cd "$WORK" && bash "$KIT/scripts/pr-review-status.sh" 5 ) > "$WORK/out.txt" 2>&1 && r=PASS || r=FAIL
x=ok
grep -q "aaaaaaa (head)" "$WORK/out.txt" || x="head review not marked"
grep -q "Reviewed the change. …" "$WORK/out.txt" || x="review summary missing or not marked as shortened"
grep -q "src/c.ts:4" "$WORK/out.txt" || x="second page of threads missing"
grep -q "replies: 2" "$WORK/out.txt" || x="reply count missing"
[ "$(grep -n 'src/b.ts' "$WORK/out.txt" | cut -d: -f1)" -lt "$(grep -n 'src/a.ts' "$WORK/out.txt" | cut -d: -f1)" ] || x="open threads not first"
grep -q -- "--full" "$WORK/out.txt" || x="no pointer to --full"
check "overview: reviews, all thread pages, open first, shortened text marked" PASS "$r" "$x"

( cd "$WORK" && bash "$KIT/scripts/pr-review-status.sh" 5 --full ) > "$WORK/out.txt" 2>&1 && r=PASS || r=FAIL
x=ok
for want in "SUMMARY-ONLY FINDING" "MULTILINE-EXPLANATION" "REPLY-TEXT" "SECOND-PAGE-FINDING" "BURIED-FINDING" "https://x/c3" "https://x/review2" "(no summary text)" "1 more replies"; do
  grep -q -- "$want" "$WORK/out.txt" || { x="missing: $want"; break; }
done
check "--full: summary-only, multiline, reply, second-page and buried findings all present" PASS "$r" "$x"

# ---- ai-task launcher -------------------------------------------------------------------
echo "ai-task launcher"
O="$WORK/origin.git"; git init -q --bare "$O"
P="$WORK/My Projects/app"; mkdir -p "$WORK/My Projects"; git clone -q "$O" "$P" 2>/dev/null
cd "$P" || exit 1
mkdir -p .ai-build scripts
cat > .ai-build/project.env <<'CFG'
DEFAULT_BRANCH="main"
INSTALL_CMD='echo "$DATABASE_URL" > installed.txt'
PORT_BASE=4100
PORT_RANGE=2
COPY_FILES=".env.local config/local.json"
DISPOSABLE="build/ *node_modules/ installed.txt"
DB_PREFIX="app_dev"
DB_CREATE_CMD='echo "create $AI_TASK_DB" >> "$TEST_DB_LOG"'
DB_ENV_CMD='if [ -n "${TEST_BAD_URL:-}" ]; then echo "DATABASE_URL=postgres://dev:s3cret@localhost:5432/shared_dev"; else echo "DATABASE_URL=postgres://dev:s3cret@localhost:5432/$AI_TASK_DB"; fi; echo DB_PASSWORD=fixture-password; echo API_TOKEN=fixture-token'
[ -n "${TEST_NO_VERIFY:-}" ] || DB_VERIFY_CMD='[ -z "${TEST_VERIFY_FAIL:-}" ] || exit 1; case "$DATABASE_URL" in */"$AI_TASK_DB") exit 0 ;; *) exit 1 ;; esac'
DB_DUMP_CMD='[ -z "${TEST_DUMP_FAIL:-}" ] || exit 1; echo "dump of $AI_TASK_DB" > "$AI_TASK_DUMP"'
DB_DROP_CMD='echo "drop $AI_TASK_DB" >> "$TEST_DB_LOG"'
RESCUE_DIR="$TEST_RESCUE_DIR"
CFG
printf '.claude/worktrees/\n.env.local\nconfig/local.json\ninstalled.txt\nbuild/\nnode_modules/\nscratch/\n.wrangler/\n' > .gitignore
cp "$KIT/scripts/ai-task.sh" scripts/
echo base > README.md; git add -A; git commit -qm init; git push -q origin HEAD:main 2>/dev/null
echo "SECRET=local" > .env.local; mkdir -p config; echo '{}' > config/local.json
git switch -qc other-work; echo "unsaved edit" >> README.md
export TEST_DB_LOG="$WORK/db.log" TEST_RESCUE_DIR="$WORK/rescue"; : > "$TEST_DB_LOG"
export TEST_CLAUDE_LOG="$WORK/claude.log"
cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${DATABASE_URL:-UNSET}" > "$TEST_CLAUDE_LOG"
EOF
chmod +x "$STUB/claude"
T="$P/.claude/worktrees"
task() { ( cd "$P" && bash scripts/ai-task.sh "$@" ) > "$WORK/out.txt" 2>&1 && echo PASS || echo FAIL; }
has() { grep -q -- "$1" "$2" 2>/dev/null && echo ok || echo "missing '$1' in $(basename "$2")"; }
gone() { [ -e "$1" ] && echo "still present: $(basename "$1")" || echo ok; }
there() { [ -e "$1" ] && echo ok || echo "missing: $(basename "$1")"; }
prlist() { echo "$2" > "$FIX/prlist-task_$1.json"; }

r=$(task start alpha --no-claude)
x=ok
[ -d "$T/alpha" ] || x="worktree not created"
[ "$x" = ok ] && [ "$(git -C "$T/alpha" branch --show-current)" = "task/alpha" ] || x="${x/ok/wrong branch}"
[ "$x" = ok ] && [ "$(git -C "$T/alpha" rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || x="${x/ok/not based on origin/main}"
[ "$x" = ok ] && x=$(has "SECRET=local" "$T/alpha/.env.local")
[ "$x" = ok ] && x=$(has "create app_dev_alpha" "$TEST_DB_LOG")
[ "$x" = ok ] && x=$(has "5432/app_dev_alpha" "$T/alpha/installed.txt")
[ "$x" = ok ] && { git -C "$T/alpha" status --porcelain | grep -q . && x="new worktree is not clean"; }
check "start: fresh worktree, files copied, task database verified, install sees the task database (path with spaces)" PASS "$r" "$x"
x=ok
for secret in s3cret fixture-password fixture-token; do
  grep -q "$secret" "$WORK/out.txt" && x="credential printed: $secret"
done
[ "$x" = ok ] && x=$(has "values withheld" "$WORK/out.txt")
check "start withholds URL, password and token settings" ok "$x"
x=ok
[ "$(stat -c %a "$T/alpha/.ai-task.env" 2>/dev/null || stat -f %Lp "$T/alpha/.ai-task.env")" = 600 ] || x="task settings are not private"
check "task settings have owner-only permissions" ok "$x"
r=$( (unset DATABASE_URL AI_TASK_DB PORT; task resume alpha) )
check "resume in a fresh environment reloads the task database before Claude" PASS "$r" "$(has '5432/app_dev_alpha' "$TEST_CLAUDE_LOG")"
rm -f "$TEST_CLAUDE_LOG"
r=$(TEST_VERIFY_FAIL=1 task resume alpha)
check "resume refuses failed database verification without starting Claude" FAIL "$r" "$(gone "$TEST_CLAUDE_LOG")"
r=$(TEST_NO_VERIFY=1 task resume alpha)
check "resume refuses a database task with no verifier" FAIL "$r" "$(gone "$TEST_CLAUDE_LOG")"
r=$(task resume missing-task)
check "resume refuses missing task settings" FAIL "$r" "$(gone "$TEST_CLAUDE_LOG")"
x=ok
[ "$(git branch --show-current)" = "other-work" ] || x="main checkout branch changed"
grep -q "unsaved edit" README.md || x="main checkout edit lost"
check "start leaves the main checkout's branch and unsaved edits alone" ok "$x"
r=$(task start alpha --no-claude); check "start refuses an existing task" FAIL "$r"
r=$(task start Bad_Name --no-claude); check "start rejects an invalid task name" FAIL "$r"

: > "$TEST_DB_LOG"
r=$(TEST_BAD_URL=1 task start wrongdb --no-claude)
x=$(gone "$T/wrongdb"); [ "$x" = ok ] && { git show-ref --quiet refs/heads/task/wrongdb && x="branch left behind"; }
[ "$x" = ok ] && x=$(has "drop app_dev_wrongdb" "$TEST_DB_LOG")
check "app resolving to another database: start undone before install, task database dropped" FAIL "$r" "$x"
r=$(TEST_NO_VERIFY=1 task start noverify --no-claude); x=$(gone "$T/noverify")
check "task database without a verification command: start refuses" FAIL "$r" "$x"

r=$(task start beta --no-claude --no-install)
pa=$(grep '^PORT=' "$T/alpha/.ai-task.env" | cut -d= -f2); pb=$(grep '^PORT=' "$T/beta/.ai-task.env" 2>/dev/null | cut -d= -f2)
x=ok; [ -n "$pb" ] && [ "$pa" != "$pb" ] || x="ports collide ($pa, $pb)"
check "start gives a second task a different port" PASS "$r" "$x"
r=$(task start gamma --no-claude --no-install)
x=$(gone "$T/gamma"); git show-ref --quiet refs/heads/task/gamma && x="branch left behind"
check "start fails cleanly when no port is free" FAIL "$r" "$x"
( cd "$P" && bash scripts/ai-task.sh list ) > "$WORK/out.txt" 2>&1 && r=PASS || r=FAIL
x=$(has "alpha" "$WORK/out.txt"); [ "$x" = ok ] && x=$(has "beta" "$WORK/out.txt")
check "list shows task worktrees" PASS "$r" "$x"
( cd "$T/beta" && bash "$P/scripts/ai-task.sh" list ) > "$WORK/out.txt" 2>&1 && r=PASS || r=FAIL
check "list works from inside a task worktree" PASS "$r" "$(has alpha "$WORK/out.txt")"

: > "$TEST_DB_LOG"
mkdir -p "$T/alpha/node_modules/x" "$T/alpha/build"; echo 1 > "$T/alpha/node_modules/x/i.js"; echo 1 > "$T/alpha/build/out.js"
r=$(task finish alpha)
x=$(gone "$T/alpha"); [ "$x" = ok ] && { grep -q "drop" "$TEST_DB_LOG" && x="database dropped without --drop-db"; }
[ "$x" = ok ] && x=$(has "kept" "$WORK/out.txt")
check "finish: disposable build output and unchanged copies removed; task database kept by default" PASS "$r" "$x"
r=$(AI_TASK_BUSY_PORTS="4100 4101" task start delta --no-claude --no-install)
check "start skips ports something is already listening on" FAIL "$r"

echo "ai-task cleanup safety (v3.4 regressions)"
task start eps --no-claude --no-install >/dev/null
mkdir -p "$T/eps/scratch"; echo "Synthetic unsaved work: no other copy." > "$T/eps/scratch/only-copy.txt"
r=$(task finish eps); x=$(there "$T/eps/scratch/only-copy.txt"); [ "$x" = ok ] && x=$(has "scratch/" "$WORK/out.txt")
check "ignored file with no other copy: finish refuses and names it" FAIL "$r" "$x"
r=$(task finish eps --rescue)
rd=$(ls -d "$TEST_RESCUE_DIR"/app/*-eps 2>/dev/null | head -n 1)
x=$(gone "$T/eps")
[ "$x" = ok ] && { [ -n "$rd" ] && cmp -s "$rd/files/scratch/only-copy.txt" <(echo "Synthetic unsaved work: no other copy.") || x="rescue copy missing or different"; }
[ "$x" = ok ] && x=$(has "FILE=scratch" "$rd/MANIFEST.txt")
[ "$x" = ok ] && [ "$(stat -c %a "$rd" 2>/dev/null || stat -f %Lp "$rd")" = "700" ] || x="${x/ok/rescue folder not private}"
[ "$x" = ok ] && { git ls-remote "$O" 'refs/heads/rescue/*' | grep -q eps && x="pushed although git had nothing to save"; }
check "finish --rescue: ignored file copied privately, verified, manifest written, then removed" PASS "$r" "$x"
r=$(task restore "$rd" eps-back)
x=ok; cmp -s "$T/eps-back/scratch/only-copy.txt" "$rd/files/scratch/only-copy.txt" || x="restored file differs"
check "restore recreates the task with the rescued file" PASS "$r" "$x"
task finish eps-back --rescue >/dev/null 2>&1

task start zeta --no-claude --no-install >/dev/null
echo "SECRET=changed-locally" > "$T/zeta/.env.local"
r=$(task finish zeta); check "changed copy of a settings file is treated as work" FAIL "$r" "$(there "$T/zeta")"
cp "$P/.env.local" "$T/zeta/.env.local"
mkdir -p "$T/zeta/.wrangler/state/d1"; echo "local rows" > "$T/zeta/.wrangler/state/d1/db.sqlite"
r=$(task finish zeta); check "local database state (.wrangler/state) is never disposable by default" FAIL "$r" "$(there "$T/zeta/.wrangler/state/d1/db.sqlite")"
rm -rf "$T/zeta/.wrangler"

r=$(STUB_PR_FAIL=1 task finish zeta); x=$(there "$T/zeta"); [ "$x" = ok ] && x=$(has "could not be confirmed" "$WORK/out.txt")
check "pull request lookup fails (HTTP 503): finish refuses" FAIL "$r" "$x"
r=$( ( cd "$P" && PATH="/usr/bin:/bin" bash scripts/ai-task.sh finish zeta ) > "$WORK/out.txt" 2>&1 && echo PASS || echo FAIL )
if PATH="/usr/bin:/bin" command -v gh >/dev/null 2>&1; then
  printf '  skip  gh missing (gh is installed in /usr/bin or /bin here)\n'
else
  check "gh not installed: finish refuses" FAIL "$r" "$(there "$T/zeta")"
fi
prlist zeta "[{\"state\":\"OPEN\",\"number\":12,\"headRefOid\":\"$(git -C "$T/zeta" rev-parse HEAD)\"}]"
( cd "$T/zeta" && git push -q origin HEAD:task/zeta 2>/dev/null ); git fetch -q origin
r=$(task finish zeta); check "finish refuses while the pull request is open" FAIL "$r" "$(there "$T/zeta")"
r=$(task finish zeta --allow-open); check "finish --allow-open removes only the local copy of a confirmed open PR" PASS "$r" "$(gone "$T/zeta")"

task start eta --no-claude --no-install >/dev/null
( cd "$T/eta" && echo h > h.txt && git add h.txt && git commit -qm h && git push -q origin HEAD:task/eta 2>/dev/null )
prlist eta "[{\"state\":\"MERGED\",\"number\":9,\"headRefOid\":\"$(git -C "$T/eta" rev-parse HEAD)\"}]"
git push -q origin --delete task/eta 2>/dev/null; git fetch -q --prune origin
r=$(task finish eta); check "finish accepts a squash-merged task whose remote branch was deleted" PASS "$r" "$(gone "$T/eta")"

task start theta --no-claude --no-install >/dev/null
( cd "$T/theta" && echo t > t.txt && git add t.txt && git commit -qm t && git push -q origin HEAD:task/theta 2>/dev/null )
prlist theta "[{\"state\":\"MERGED\",\"number\":10,\"headRefOid\":\"$(git -C "$T/theta" rev-parse HEAD)\"}]"
( cd "$T/theta" && echo late > late.txt && git add late.txt && git commit -qm "after merge" )
git push -q origin --delete task/theta 2>/dev/null; git fetch -q --prune origin
r=$(task finish theta); check "finish refuses a merged task with commits made after the merge" FAIL "$r" "$(there "$T/theta")"

echo "edit" >> "$T/beta/README.md"
r=$(task finish beta); check "finish refuses when there is uncommitted work" FAIL "$r" "$(there "$T/beta")"
git -C "$T/beta" commit -qam "local only"; echo "more" >> "$T/beta/README.md"
before=$(git -C "$T/beta" rev-parse HEAD)
r=$(TEST_RESCUE_DIR=/dev/null/no-such-place task finish beta --rescue)
check "rescue folder cannot be created: nothing removed" FAIL "$r" "$(there "$T/beta")"
r=$(task finish beta --rescue)
rb=$(git ls-remote "$O" 'refs/heads/rescue/*beta' | awk '{print $2}' | head -n 1)
x=$(gone "$T/beta"); [ "$x" = ok ] && { [ -n "$rb" ] && git --git-dir="$O" merge-base --is-ancestor "$before" "$rb" || x="unpushed commit not in rescue branch"; }
check "finish --rescue pushes uncommitted and unpushed work, verifies, then removes" PASS "$r" "$x"
rd=$(ls -d "$TEST_RESCUE_DIR"/app/*-beta | head -n 1)
r=$(task restore "$rd" beta-back)
x=ok; grep -q "more" "$T/beta-back/README.md" || x="rescued edit missing after restore"
check "restore from a rescue branch brings back committed and uncommitted work" PASS "$r" "$x"
rm -f "$TEST_CLAUDE_LOG"
r=$( (unset DATABASE_URL AI_TASK_DB PORT; task resume beta-back) )
check "restored database task cannot resume until connection settings verify" FAIL "$r" "$(gone "$TEST_CLAUDE_LOG")"

: > "$TEST_DB_LOG"
r=$(TEST_DUMP_FAIL=1 task finish beta-back --rescue --drop-db)
x=$(there "$T/beta-back"); [ "$x" = ok ] && { grep -q drop "$TEST_DB_LOG" && x="database dropped after a failed dump"; }
check "database dump fails: nothing removed, database kept" FAIL "$r" "$x"
r=$(task finish beta-back --rescue --drop-db)
rd=$(ls -dt "$TEST_RESCUE_DIR"/app/*-beta-back* | head -n 1)
x=$(gone "$T/beta-back"); [ "$x" = ok ] && { [ -s "$rd/database.dump" ] || x="dump missing"; }
[ "$x" = ok ] && x=$(has "drop app_dev_beta$" "$TEST_DB_LOG"); [ "$x" = ok ] && x=$(has "DB_STATE=dropped" "$rd/MANIFEST.txt")
check "finish --drop-db on a restored task: dump written and checked, then its original database dropped" PASS "$r" "$x"
x=ok; [ "$(ls -d "$TEST_RESCUE_DIR"/app/*-beta-back* | wc -l | tr -d ' ')" -ge 2 ] || x="rescue folder reused"
check "a second rescue in the same second gets its own folder" ok "$x"

echo "ai-task fixes from the sandbox review"
for t in gamma theta; do task finish "$t" --rescue >/dev/null 2>&1; done   # free ports: this project has two
task start iota --no-claude --no-install >/dev/null
( cd "$T/iota" && echo i > i.txt && git add i.txt && git commit -qm i && git push -q origin HEAD:task/iota 2>/dev/null ); git fetch -q origin
git --git-dir="$O" update-ref -d refs/heads/task/iota      # deleted on the remote, never merged
r=$(task finish iota); x=$(there "$T/iota"); [ "$x" = ok ] && x=$(has "commits not on any remote branch" "$WORK/out.txt")
check "branch deleted on the remote without merging: finish refuses (stale tracking ref pruned)" FAIL "$r" "$x"
r=$( ( cd "$P" && git remote set-url origin "$WORK/no-such-remote.git" && bash scripts/ai-task.sh finish iota; rc=$?; git remote set-url origin "$O"; exit $rc ) > "$WORK/out.txt" 2>&1 && echo PASS || echo FAIL )
x=$(there "$T/iota"); [ "$x" = ok ] && x=$(has "could not fetch origin" "$WORK/out.txt")
check "remote unreachable: finish refuses instead of trusting cached remote state" FAIL "$r" "$x"
task finish iota --rescue >/dev/null 2>&1

task start kappa --no-claude --no-install >/dev/null
echo first > "$T/kappa/version.txt"
task finish kappa --rescue >/dev/null 2>&1
rd1=$(ls -dt "$TEST_RESCUE_DIR"/app/*-kappa | head -n 1)
task restore "$rd1" >/dev/null 2>&1
echo second > "$T/kappa/version.txt"
task finish kappa --rescue >/dev/null 2>&1
r=$(task restore "$rd1" kappa-old)
x=ok; [ "$(cat "$T/kappa-old/version.txt" 2>/dev/null)" = first ] || x="restored $(cat "$T/kappa-old/version.txt" 2>/dev/null || echo nothing), not the rescued 'first'"
check "restore uses the commit in its manifest after a later same-day rescue moved the branch" PASS "$r" "$x"
task finish kappa-old --rescue >/dev/null 2>&1

rd2="$WORK/rescue-nodb"; cp -Rp "$rd1" "$rd2"; sed -i.bak 's/^DB=.*/DB=/' "$rd2/MANIFEST.txt"
r=$(task restore "$rd2" kappa-nodb); x=$(there "$T/kappa-nodb")
check "restore of a task without a database exits successfully" PASS "$r" "$x"
task finish kappa-nodb --rescue >/dev/null 2>&1

LOCK="$(git -C "$P" rev-parse --path-format=absolute --git-common-dir)/ai-task-port.lock"
{ bash -c 'exec 9>>"$1"; perl -e "use Fcntl qw(:flock); open(my \$f, \">&=\", 9); flock(\$f, LOCK_EX)"; kill -9 $$' _ "$LOCK"; } 2>/dev/null
r=$(task start mu --no-claude --no-install)
check "port lock held by a launcher that was killed is free again" PASS "$r" "$(there "$T/mu/.ai-task.env")"
perl -e 'use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; sleep 1' "$LOCK" & holder=$!
sleep 0.3
r=$(task start nu --no-claude --no-install)
x=ok; kill -0 "$holder" 2>/dev/null && x="start finished while another process held the lock"
wait "$holder"
[ "$x" = ok ] && x=$(there "$T/nu/.ai-task.env")
[ "$x" = ok ] && [ "$(grep '^PORT=' "$T/nu/.ai-task.env")" != "$(grep '^PORT=' "$T/mu/.ai-task.env")" ] || x="${x/ok/same port as mu}"
check "start waits for another start holding the port lock, then picks a different port" PASS "$r" "$x"
task finish mu --rescue >/dev/null 2>&1; task finish nu --rescue >/dev/null 2>&1
# rho and sigma hash to the same first-choice port in this two-port range. Without the lock both
# pick it before either writes its settings, and their simultaneous `git worktree add` calls also
# collide on .git/config, so one start fails (observed 5 of 5 runs with the lock disabled).
( cd "$P" && bash scripts/ai-task.sh start rho --no-claude --no-install ) > "$WORK/rho.txt" 2>&1 & p1=$!
( cd "$P" && bash scripts/ai-task.sh start sigma --no-claude --no-install ) > "$WORK/sigma.txt" 2>&1 & p2=$!
r=PASS; wait "$p1" || r=FAIL; wait "$p2" || r=FAIL
x=ok; [ "$(grep '^PORT=' "$T/rho/.ai-task.env" 2>/dev/null)" != "$(grep '^PORT=' "$T/sigma/.ai-task.env" 2>/dev/null)" ] || x="both tasks got the same port"
check "two starts at the same moment both succeed, with different ports" PASS "$r" "$x"
task finish rho --rescue >/dev/null 2>&1; task finish sigma --rescue >/dev/null 2>&1

task start pi --no-claude --no-install >/dev/null
git -C "$T/pi" config status.showUntrackedFiles no
echo "draft" > "$T/pi/untracked-draft.txt"; mkdir -p "$T/pi/scratch"; echo "local" > "$T/pi/scratch/data.txt"
r=$(task finish pi); x=$(there "$T/pi/untracked-draft.txt"); [ "$x" = ok ] && x=$(has "untracked-draft.txt" "$WORK/out.txt"); [ "$x" = ok ] && x=$(has "scratch/" "$WORK/out.txt")
check "status.showUntrackedFiles=no: finish still sees untracked and ignored work" FAIL "$r" "$x"
r=$(task finish pi --rescue); rd=$(ls -dt "$TEST_RESCUE_DIR"/app/*-pi | head -n 1)
x=$(gone "$T/pi"); [ "$x" = ok ] && { git ls-remote "$O" 'refs/heads/rescue/*-pi' | grep -q . || x="untracked file not pushed"; }
[ "$x" = ok ] && { [ -f "$rd/files/scratch/data.txt" ] || x="ignored file not rescued"; }
check "status.showUntrackedFiles=no: finish --rescue saves untracked and ignored work" PASS "$r" "$x"

task start tau --no-claude --no-install >/dev/null
( cd "$T/tau" && echo s > s.txt && git add s.txt && git commit -qm s && git push -q origin HEAD:task/tau 2>/dev/null )
th=$(git -C "$T/tau" rev-parse HEAD)
prlist tau "[{\"state\":\"MERGED\",\"number\":11,\"headRefOid\":\"$th\"}]"
mkdir -p "$T/tau/scratch"; echo "keep me" > "$T/tau/scratch/notes.txt"
git push -q origin --delete task/tau 2>/dev/null; git fetch -q --prune origin
r=$(task finish tau --rescue); rd=$(ls -dt "$TEST_RESCUE_DIR"/app/*-tau | head -n 1)
x=$(gone "$T/tau"); [ "$x" = ok ] && { git ls-remote "$O" 'refs/heads/rescue/*-tau' | grep -q "^$th" || x="squash-merged commit not pushed to a rescue branch"; }
[ "$x" = ok ] && x=$(has "HEAD=$th" "$rd/MANIFEST.txt")
check "squash-merged task with its branch deleted: rescue keeps a fetchable commit" PASS "$r" "$x"
G="$WORK/fresh-clone"; git clone -q "$O" "$G" 2>/dev/null; mkdir -p "$G/.ai-build" "$G/scripts"; cp "$P/.ai-build/project.env" "$G/.ai-build/"; cp "$P/scripts/ai-task.sh" "$G/scripts/"
r=$( ( cd "$G" && bash scripts/ai-task.sh restore "$rd" tau-back ) > "$WORK/out.txt" 2>&1 && echo PASS || echo FAIL )
x=ok; [ "$(git -C "$G/.claude/worktrees/tau-back" rev-parse HEAD 2>/dev/null)" = "$th" ] || x="restore in a fresh clone did not reach $th"
[ "$x" = ok ] && { [ -f "$G/.claude/worktrees/tau-back/scratch/notes.txt" ] || x="rescued file missing"; }
check "that rescue restores in a fresh clone" PASS "$r" "$x"
cd "$WORK" || exit 1

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
