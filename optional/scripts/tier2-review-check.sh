#!/usr/bin/env bash
# EXPERIMENTAL. Do not make this a required check until the live tests in README.md pass.
#
# Requires exactly one tier label. For tier-2 pull requests, fails unless the newest
# non-dismissed review by the Codex reviewer account was made on the pull request's head
# commit. Fails closed: if it cannot verify, it blocks. Reads the head commit and labels live
# from the API rather than from the triggering event, so a late or replaced run cannot act on
# stale data.
#
# Unknown until tested live: what Codex posts when it finds nothing. If a clean review is
# not a GitHub review tied to a commit, this check will block clean tier-2 pull requests.
#
# Trust note: pull_request_review events run the pull request's copy of this workflow.
# signoff-guard always protects these files, so changing them requires owner sign-off.
#
# Inputs: REVIEWER_LOGIN PR_NUMBER GH_REPO GH_TOKEN
set -euo pipefail

info="$(gh pr view "$PR_NUMBER" --json headRefOid,isCrossRepository,labels \
  --jq '[.headRefOid, (.isCrossRepository | tostring), ([.labels[].name] | join(","))] | @tsv')"
IFS=$'\t' read -r HEAD_SHA cross labels_csv <<< "$info"

if [ "$cross" != "false" ]; then
  echo "::error::Pull requests from forks are not supported by this check."
  exit 1
fi

count=0
tier=""
IFS=',' read -ra labels <<< "${labels_csv:-}"
for l in "${labels[@]}"; do
  case "$l" in tier-0|tier-1|tier-2) count=$((count + 1)); tier="$l" ;; esac
done
if [ "$count" -ne 1 ]; then
  echo "::error::Apply exactly one of tier-0, tier-1 or tier-2 (found $count)."
  exit 1
fi
if [ "$tier" != "tier-2" ]; then
  echo "$tier: no review gate."
  exit 0
fi

if [ -z "${REVIEWER_LOGIN:-}" ]; then
  echo "::error::CODEX_REVIEWER_LOGIN is not set, so the review cannot be verified."
  exit 1
fi

reviewed="$(gh api --paginate "repos/$GH_REPO/pulls/$PR_NUMBER/reviews?per_page=100" \
  | jq -rs --arg u "$REVIEWER_LOGIN" '
      [add[]? | select(.user.login == $u and .state != "DISMISSED" and .state != "PENDING")]
      | sort_by(.submitted_at) | last | .commit_id // ""')"

if [ -z "$reviewed" ]; then
  echo "::error::No current review from $REVIEWER_LOGIN. Comment @codex review."
  exit 1
fi

if [ "$reviewed" != "$HEAD_SHA" ]; then
  echo "::error::Newest Codex review is on ${reviewed:0:7}, but the head is ${HEAD_SHA:0:7}. Comment @codex review."
  exit 1
fi

echo "Newest Codex review covers the head commit ${HEAD_SHA:0:7}."
