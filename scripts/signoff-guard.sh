#!/usr/bin/env bash
# signoff-guard: sets the commit status "owner-signoff" on a pull request's head commit.
#   success - the pull request changes no sign-off paths, or an owner's "/signoff <commit>"
#             comment approves a commit in this pull request whose sign-off paths are
#             identical to the current head's.
#   pending - the head changed while this run was checking; the run for the new head decides.
#   failure - anything else, including forks, malformed sign-offs, and any error while reading
#             GitHub or the repository. Nothing that failed to verify can produce success.
#
# TRUST MODEL - read before editing
# - Triggers are pull_request_target and issue_comment. GitHub runs the default branch's copy
#   of this workflow for both, and the workflow checks out the default branch, so this script
#   and the path list are not taken from the pull request.
# - The pull request's commits are fetched as data only: compared with git, never executed,
#   sourced, built or installed. Do not add steps that run pull request code.
# - What this does NOT guarantee:
#   * Any other workflow in this repository with permission to write statuses can post an
#     "owner-signoff" status too, and the newest status wins. Requiring GitHub Actions as the
#     status source does not tell workflows apart. Protecting .github/workflows/** (below)
#     makes such changes visible and needs sign-off to merge; it does not stop a workflow on a
#     pull request branch from posting a status before you review it.
#   * A "/signoff" comment shows that someone using an owner's login posted it, not that a
#     human reviewed the change. Agents act through that login too.
#   * If GitHub cannot be reached to post a new status, the previous status stays. Revocation
#     is not guaranteed to take effect during an outage.
#   Stronger enforcement needs separate agent and owner identities and an app whose
#   credentials editable workflows cannot reach. That is not built.
#
# STATE MODEL
# - Each run reads the current head and comments from the API, not the triggering event, and
#   reports on the commit it checked. The run after the last event decides.
# - Sign-off covers the sign-off paths exactly as they are in the approved commit.
# - The script never edits the pull request, so it never depends on events it causes.
#
# Inputs: PR_NUMBER GH_REPO BASE_REF OWNERS(comma-separated) GH_TOKEN
#         FETCHED_HEAD_REF (the pull request head the workflow fetched; default origin/pr-head)
#         optional: STATUS_CONTEXT PATHS_FILE
set -euo pipefail

CONTEXT="${STATUS_CONTEXT:-owner-signoff}"
PATHS_FILE="${PATHS_FILE:-.github/signoff-paths.txt}"
FETCHED_HEAD_REF="${FETCHED_HEAD_REF:-refs/remotes/origin/pr-head}"
ALWAYS_PROTECTED=(
  ".github/workflows/**"
  "scripts/signoff-guard.sh"
  ".github/signoff-paths.txt"
  "scripts/tier2-review-check.sh"
)

HEAD=""
post() { # state description  (on $HEAD)
  local desc="${2:0:139}"
  # "|| return 1" matters: set -e does not apply inside a function called from "||".
  gh api -X POST "repos/$GH_REPO/statuses/$HEAD" \
    -f state="$1" -f context="$CONTEXT" -f description="$desc" >/dev/null || return 1
  echo "$CONTEXT on ${HEAD:0:7}: $1 - $2"
}
fail_closed() { # reason ; posts failure if a head is known, then stops
  trap - ERR
  # Inside a subshell (for example a command substitution) only signal failure; the main
  # script then fails and posts. Exiting 0 here would let the main script carry on.
  if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then exit 1; fi
  if [ -n "$HEAD" ]; then
    post failure "$1" || { echo "Could not post failure status: $1" >&2; exit 1; }
    exit 0
  fi
  echo "::error::$1 (no head commit known, so no status was posted; the previous status stays)" >&2
  exit 1
}
# Any unexpected failure in the main script ends in a failure status, never a stale one.
trap 'fail_closed "Sign-off check failed unexpectedly; see the workflow log"' ERR

# The head the workflow fetched is the fallback: it is the pull request's commit, never the
# default branch's.
FETCHED="$(git rev-parse --verify --quiet "${FETCHED_HEAD_REF}^{commit}" || true)"
[ -n "$FETCHED" ] || fail_closed "Pull request commits were not fetched"
HEAD="$FETCHED"

if ! LIVE="$(gh pr view "$PR_NUMBER" --json headRefOid --jq .headRefOid)" || [ -z "$LIVE" ]; then
  fail_closed "Could not read the pull request's current head"
fi
if [ "$LIVE" != "$FETCHED" ]; then
  HEAD="$LIVE"
  post pending "Head changed during the check; the run for the new commit decides" ||
    { echo "Could not post pending status" >&2; exit 1; }
  exit 0
fi
post pending "Checking owner sign-off"

if ! cross="$(gh pr view "$PR_NUMBER" --json isCrossRepository --jq .isCrossRepository)"; then
  fail_closed "Could not read the pull request's details"
fi
[ "$cross" = "false" ] || fail_closed "Pull requests from forks are not supported"

# Policy comes from the trusted checkout, never from the pull request.
specs=()
for p in "${ALWAYS_PROTECTED[@]}"; do specs+=(":(glob)$p"); done
if [ -f "$PATHS_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do   # keeps a final line with no newline
    line="${line%%#*}"
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$line" ] && specs+=(":(glob)$line")
  done < "$PATHS_FILE"
fi

changed="$(git diff --name-only "$BASE_REF...$HEAD" -- "${specs[@]}")"
if [ -z "$changed" ]; then
  post success "No sign-off paths changed"
  exit 0
fi
echo "Sign-off paths changed in this pull request:"
echo "$changed"

# Read every comment. Any error, even after some output, means nothing is approved.
if ! comments="$(gh api --paginate "repos/$GH_REPO/issues/$PR_NUMBER/comments?per_page=100" \
       --jq '.[] | [.user.login, .updated_at, ((.body // "") | gsub("\r"; "") | split("\n") | map(select(test("\\S"))) | (.[0] // ""))] | @tsv')"; then
  fail_closed "Could not read all pull request comments"
fi

# Latest sign-off command from an owner: "/signoff <commit>" or "/signoff revoke".
latest=""
while IFS=$'\t' read -r who when first; do
  [ -n "$who" ] || continue
  case ",${OWNERS}," in *",${who},"*) ;; *) continue ;; esac
  # The command is the first non-blank line, ignoring spaces around it.
  cmd="$(printf '%s' "$first" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if printf '%s' "$cmd" | grep -Eq '^/signoff[[:space:]]+([0-9a-fA-F]{7,40}|revoke)$'; then
    latest="$when $(printf '%s' "$cmd" | awk '{print $2}')"
  elif printf '%s' "$cmd" | grep -Eiq '^/sign-?off([[:space:]]|$)'; then
    # A sign-off command this guard cannot read (typo, wrong case, extra words) must never
    # leave an earlier approval standing: treat it as a revoke, so the owner sees red.
    echo "Unrecognized sign-off command from $who treated as revoke: $cmd"
    latest="$when revoke"
  fi
done < <(printf '%s\n' "$comments" | sort -t $'\t' -k2,2)

approved="${latest#* }"
if [ -z "$latest" ] || [ "$approved" = "revoke" ]; then
  fail_closed "Needs owner sign-off: comment /signoff <commit> after reviewing it"
fi
sha="$(git rev-parse --verify --quiet "${approved}^{commit}" || true)"
[ -n "$sha" ] || fail_closed "Sign-off names a commit that is unknown or ambiguous: $approved"
git merge-base --is-ancestor "$sha" "$HEAD" ||
  fail_closed "Signed-off commit ${sha:0:7} is not part of this pull request's history"

after="$(git diff --name-only "$sha" "$HEAD" -- "${specs[@]}")"
if [ -n "$after" ]; then
  echo "Changed since the signed-off commit ${sha:0:7}:"
  echo "$after"
  fail_closed "Sign-off paths changed after sign-off at ${sha:0:7}; sign off again"
fi

trap - ERR
post success "Signed off at ${sha:0:7}"
