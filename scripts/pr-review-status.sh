#!/usr/bin/env bash
# Shows a pull request's review state.
#
# Usage: bash scripts/pr-review-status.sh <pr-number>          overview
#        bash scripts/pr-review-status.sh <pr-number> --full   complete text
#
# Overview: the head commit; each review with the commit it covered and the first line of its
#   summary; each inline thread with status, location, reply count and first line; the first
#   line of each conversation comment. Shortened text ends with "…".
# --full: the complete text of every review summary, every thread comment and reply, and every
#   conversation comment, each with a link. Read --full before acting on findings: findings can
#   sit in a review summary, deep in a comment, or in a reply.
#
# Why this exists: `gh pr view --comments` does not show inline review comments.
# Needs: gh (signed in). Reviews, conversation comments and review threads are fully
# paginated. LIMIT: within a single thread only the first 100 comments are fetched; when a
# thread has more, --full prints how many are missing and the thread link. Open that link
# and read the rest before acting on that thread.
set -euo pipefail

n="${1:?usage: pr-review-status.sh <pr-number> [--full]}"
mode="${2:-overview}"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
owner="${repo%/*}"
name="${repo#*/}"
head="$(gh pr view "$n" --json headRefOid --jq .headRefOid)"

# jq helpers: first line, shortened, marked when anything was cut; head marker.
FL='def fl: ((. // "") | gsub("\r"; "")) as $b | ($b | split("\n")) as $l
      | (($l[0] // "") | .[0:120]) + (if (($l | length) > 1 and ($l[1:] | join("") | length) > 0) or (($l[0] // "") | length) > 120 then " …" else "" end);'
HM="def hm: ((. // \"\")[0:7]) + (if . == \"$head\" then \" (head)\" else \"\" end);"

echo "Pull request #$n in $repo"
echo "Head commit: $head"

echo
echo "== Reviews"
if [ "$mode" = "--full" ]; then
  gh api --paginate "repos/$repo/pulls/$n/reviews?per_page=100" --jq "$HM"'
    .[] | "--- Review \(.id) by \(.user.login): \(.state) on \(.commit_id | hm), \(.submitted_at)\n\(.html_url)\n\((.body // "") | if . == "" then "(no summary text)" else . end)\n"'
else
  gh api --paginate "repos/$repo/pulls/$n/reviews?per_page=100" --jq "$FL $HM"'
    .[] | [.user.login, .state, (.commit_id | hm), .submitted_at, (.body | fl)] | @tsv'
fi

echo
echo "== Inline review threads"
Q='query($owner: String!, $name: String!, $n: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $n) {
      reviewThreads(first: 50, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line
          comments(first: 100) { totalCount nodes { author { login } body url createdAt } }
        }
      }
    }
  }
}'
ST='def st: if .isResolved then "resolved" elif .isOutdated then "OPEN (outdated)" else "OPEN" end;'
if [ "$mode" = "--full" ]; then
  TJ="$ST"'.data.repository.pullRequest.reviewThreads as $t
    | ($t.nodes[] | "--- Thread \(.id): \(st) at \(.path):\(.line // 0)\n"
        + ([.comments.nodes[] | "* \(.author.login // "?") \(.createdAt) \(.url)\n\(.body // "")\n"] | join("\n"))
        + (if .comments.totalCount > (.comments.nodes | length)
           then "\n(\(.comments.totalCount - (.comments.nodes | length)) more replies; open the thread link)\n" else "" end)),
      "PAGE\t\($t.pageInfo.hasNextPage)\t\($t.pageInfo.endCursor // "")"'
else
  TJ="$FL $ST"'.data.repository.pullRequest.reviewThreads as $t
    | ($t.nodes[] | [ (if .isResolved then "1" else "0" end), st,
        "\(.path):\(.line // 0)", (.comments.nodes[0].author.login // "?"),
        "replies: \(.comments.totalCount - 1)", (.comments.nodes[0].body | fl) ] | @tsv),
      "PAGE\t\($t.pageInfo.hasNextPage)\t\($t.pageInfo.endCursor // "")"'
fi

after=""
rows=""
while :; do
  args=(-F owner="$owner" -F name="$name" -F n="$n" -f query="$Q")
  [ -n "$after" ] && args+=(-F after="$after")
  out="$(gh api graphql "${args[@]}" --jq "$TJ")"
  page_info="$(printf '%s\n' "$out" | tail -n 1)"
  body="$(printf '%s\n' "$out" | sed '$d')"
  if [ "$mode" = "--full" ]; then
    [ -n "$body" ] && printf '%s\n' "$body"
  else
    [ -n "$body" ] && rows="${rows}${body}"$'\n'
  fi
  IFS=$'\t' read -r _ has_next after <<< "$page_info"
  [ "$has_next" = "true" ] || break
done
if [ "$mode" != "--full" ] && [ -n "$rows" ]; then
  printf '%s' "$rows" | sort -s -t $'\t' -k1,1 | cut -f2-
fi

echo
echo "== Conversation comments"
if [ "$mode" = "--full" ]; then
  gh api --paginate "repos/$repo/issues/$n/comments?per_page=100" \
    --jq '.[] | "--- Comment by \(.user.login), \(.created_at)\n\(.html_url)\n\(.body // "")\n"'
else
  gh api --paginate "repos/$repo/issues/$n/comments?per_page=100" \
    --jq "$FL"'.[] | [.user.login, .created_at, (.body | fl)] | @tsv'
  echo
  echo "Complete text: bash scripts/pr-review-status.sh $n --full"
fi
