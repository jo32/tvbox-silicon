#!/bin/bash
# Gives a closed feedback issue the label that pays its reporter points (Services/accounts/src/feedback.ts):
# `adopted` for an enhancement, `fixed` otherwise, but only when a merged pull request or a commit on main closed
# it ("Fixes #N"). Issues closed by hand are left alone: questions, "already exists" and source problems earn nothing.
# Usage: label-fixed-feedback.sh <issue number>   (DRY_RUN=1 prints instead of labeling)
set -euo pipefail
repo=${GITHUB_REPOSITORY:-jo32/tvbox-silicon}
number=$1

read -r state reason labels < <(gh api "repos/$repo/issues/$number" \
  --jq '[.state, (.state_reason // "none"), ([.labels[].name] | join(",") | if . == "" then "-" else . end)] | @tsv')
if [ "$state" != closed ] || [ "$reason" != completed ]; then echo "#$number: $state/$reason, skipped"; exit 0; fi
case ",$labels," in *,feedback,*) ;; *) echo "#$number: not feedback, skipped"; exit 0 ;; esac
for done in fixed adopted duplicate invalid wontfix spam; do
  case ",$labels," in *,$done,*) echo "#$number: already $done, skipped"; exit 0 ;; esac
done

# The closer can lag the closed event by a moment, so ask a few times.
closer=""
for attempt in 1 2 3; do
  closer=$(gh api graphql -F number="$number" -f owner="${repo%/*}" -f name="${repo#*/}" -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { issue(number: $number) {
        timelineItems(itemTypes: [CLOSED_EVENT], last: 1) { nodes { ... on ClosedEvent {
          closer { __typename ... on PullRequest { number merged } ... on Commit { abbreviatedOid } } } } } } } }' \
    --jq '.data.repository.issue.timelineItems.nodes[0].closer // empty
      | if .__typename == "PullRequest" then (if .merged then "PR #\(.number)" else empty end)
        else "commit \(.abbreviatedOid)" end')
  [ -n "$closer" ] && break
  [ "$attempt" -lt 3 ] && sleep 10
done
if [ -z "$closer" ]; then echo "#$number: closed by hand, skipped"; exit 0; fi

case ",$labels," in *,enhancement,*) label=adopted ;; *) label=fixed ;; esac
if [ "${DRY_RUN:-}" = 1 ]; then echo "#$number: would add $label (closed by $closer)"; exit 0; fi
gh issue edit "$number" --repo "$repo" --add-label "$label" >/dev/null
echo "#$number: added $label (closed by $closer)"
