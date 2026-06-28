---
name: loop-agent
description: Runs one autonomous development cycle — addresses open PR review threads and merge conflicts (Phase A), then implements the oldest Linear issue assigned and labeled "Ready for agent" (Phase B). Use when executing the dev loop, processing PR review feedback, or picking up ready Linear issues via /loop.
---

# Combined Loop Agent

You are ONE iteration of the autonomous development loop covering both PR cleanup (Phase A) and issue implementation (Phase B). Process at most one PR and one issue per invocation, then STOP. **Fail closed:** on any unrecoverable failure, stop, keep any worktree intact, and report exactly what failed.

## Auto-detect repo context

Run these at the start of every invocation:

```bash
# GitHub repo in owner/name form
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')

# Local repo root and derived worktrees directory
REPO_PATH=$(git rev-parse --show-toplevel)
WORKTREES_DIR="${REPO_PATH}-worktrees"
mkdir -p "$WORKTREES_DIR"

# GitHub username for author-filtering
GH_USER=$(gh api user --jq '.login')
```

All subsequent shell commands use `$REPO`, `$REPO_PATH`, `$WORKTREES_DIR`, and `$GH_USER`.

## Linear API helper

All Linear interactions use the GraphQL API directly via `curl` and `jq`. Export `LINEAR_API_KEY` before running this skill.

```bash
LINEAR_API_KEY="${LINEAR_API_KEY:?LINEAR_API_KEY is required — export it before running}"

# Helper: run a Linear GraphQL query or mutation.
# Usage: linear_gql '<query>' '<json-variables-object>'
# Variables default to {} when omitted.
linear_gql() {
  local query="$1"
  local vars="{}"
  [ -n "${2-}" ] && vars="$2"
  curl -sf --retry 2 --connect-timeout 10 --max-time 30 -X POST https://api.linear.app/graphql \
    -H "Authorization: Bearer $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -cn --arg q "$query" --argjson v "$vars" '{query:$q,variables:$v}')"
}
```

`jq` must be available. All `linear_gql` calls below assume this function is defined in the current shell.

## Configuration

- Base branch: `main`
- Worktrees dir: `$WORKTREES_DIR` (derived above — sibling of repo root with `-worktrees` suffix)
- Linear input label: `Ready for agent`
- Linear in-progress label: `In Progress by agent`
- Linear ready label: `Ready for human review`
- GitHub ready label: `Ready for human review`
- Linear in-progress state: `In Progress`
- Quality gate: `pnpm ts:check` then `pnpm lint:fix`; also run `pnpm test:unit` and `pnpm test:acceptance:local` when present
- CI fix retry cap: 3

Resolve all Linear label/state names case-insensitively against live data.

---

## Phase A — PR Cleanup

### A1. Select one PR

List open PRs authored by you (oldest first), excluding any already labeled `Ready for human review`:

```bash
gh pr list --repo "$REPO" --author "@me" --state open \
  --json number,title,headRefName,mergeable,labels,url \
  --jq 'sort_by(.number) | map(select((.labels // []) | map(.name) | index("Ready for human review") | not))'
```

**Exclude collisions first.** For each candidate, compute its worktree dir `$WORKTREES_DIR/${headRefName//\//-}`. If that directory already exists, the PR is still owned by a prior cycle — skip it (note it in your report). Only consider PRs whose worktree dir does NOT exist.

Among remaining candidates, choose with this priority:

1. Oldest PR with ≥1 unresolved review thread (`isResolved == false`) OR `mergeable == "CONFLICTING"` → process (steps A2–A5), then run the promotion check (A6).
2. Otherwise, oldest PR that passes the A6 promotion check → go straight to A6.
3. Otherwise, `No PRs need work` → skip to Phase B.

Fetch review threads for each candidate to determine (1):

```bash
gh api graphql -f query='
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      reviewThreads(first:100){ totalCount nodes{
        id isResolved isOutdated path line
        comments(first:50){ nodes{ databaseId author{login} body } }
      }}
    }
  }
}' -f owner="<OWNER>" -f name="<NAME>" -F number=<NUMBER>
```

### A2. Worktree on the PR branch

```bash
BRANCH="<headRefName>"
DIR="$WORKTREES_DIR/${BRANCH//\//-}"
[ -e "$DIR" ] && { echo "Worktree $DIR already exists — owned by a prior cycle; skipping PR"; exit 0; }
git -C "$REPO_PATH" fetch origin "$BRANCH"
git -C "$REPO_PATH" worktree add "$DIR" "$BRANCH"
cd "$DIR"
```

Do all PR work with the shell cwd inside `$DIR`. Every git command (including `git push`) must run from `$DIR`.

### A3. Address every unresolved review thread

For each thread with `isResolved == false` (human reviewers and bots alike): read the comment and `path`/`line`, make the fix in the worktree, then reply and resolve:

```bash
gh api graphql -f query='mutation($threadId:ID!,$body:String!){
  addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$threadId, body:$body}){ comment{ id } }
}' -f threadId="<THREAD_ID>" -f body="<short fix description>"

gh api graphql -f query='mutation($threadId:ID!){
  resolveReviewThread(input:{threadId:$threadId}){ thread{ id isResolved } }
}' -f threadId="<THREAD_ID>"
```

If a thread asks for something incorrect or out of scope, reply explaining why and resolve it anyway; do not silently ignore it.

### A4. Fix conflicts (never force-push)

```bash
git fetch origin main
git merge origin/main
```

If conflicts: resolve them in the worktree, then `git add -A && git commit --no-edit`. If too tangled to resolve confidently, STOP and report.

### A5. Re-run gate, push, wait for CI

```bash
pnpm ts:check
pnpm lint:fix
git add -A && git commit -m "chore: address review feedback and conflicts" || true
git push origin "$BRANCH"
gh pr checks <NUMBER> --repo "$REPO" --watch --fail-fast
```

If CI fails, first re-run the failing checks once before touching code:

```bash
FAILED_RUN_ID=$(gh pr checks <NUMBER> --repo "$REPO" --json name,conclusion,link \
  --jq '.[] | select(.conclusion == "FAILURE") | .link' | grep -oE '[0-9]+$' | head -1)
gh run rerun --failed "$FAILED_RUN_ID"
gh pr checks <NUMBER> --repo "$REPO" --watch --fail-fast
```

If it passes on retry, proceed. If still failing, fix in the worktree and push again (retry cap 3). After 3 failures, STOP and report.

### A6. Promotion check

Promote ONLY if ALL four hold:

```bash
# (a) ≥1 review submitted (human or bot):
gh pr view <NUMBER> --repo "$REPO" --json reviews --jq '.reviews | length'   # must be ≥ 1
# (b) all threads resolved: re-run A3 GraphQL query; every node isResolved == true
# (c) no conflicts:
gh pr view <NUMBER> --repo "$REPO" --json mergeable --jq '.mergeable'         # == "MERGEABLE"
# (d) CI green:
gh pr checks <NUMBER> --repo "$REPO"                                          # exit 0
```

- (a) fails → skip promotion this cycle; leave fixes pushed; re-evaluate next cycle once a reviewer has looked.
- (b) fails (new bot threads appeared after your push in A5) → do NOT promote; end cycle; the PR will be re-selected next cycle.
- All four pass → promote:

  **Linear (two-step lookup via API):**

  ```bash
  # Step 1: find the issue with "In Progress by agent" label whose branchName matches the PR head branch
  INPROGRESS_JSON=$(linear_gql 'query {
    issues(
      filter: { labels: { name: { eqIgnoreCase: "In Progress by agent" } } }
      first: 50
    ) { nodes { id identifier branchName team { id } labels { nodes { id name } } } }
  }')

  LIN_MATCHED=$(echo "$INPROGRESS_JSON" | jq -c \
    --arg b "$BRANCH" '.data.issues.nodes[] | select(.branchName == $b)' | head -1)

  # Step 2: if not found, extract identifier from branch name (e.g. david/fal-136-... → FAL-136)
  if [ -z "$LIN_MATCHED" ]; then
    LIN_IDENTIFIER=$(echo "$BRANCH" | grep -oiE '[A-Za-z]+-[0-9]+' | head -1 | tr '[:lower:]' '[:upper:]')
    if [ -n "$LIN_IDENTIFIER" ]; then
      LIN_MATCHED=$(linear_gql 'query($id: String!) {
        issue(id: $id) { id identifier branchName team { id } labels { nodes { id name } } }
      }' "$(jq -cn --arg id "$LIN_IDENTIFIER" '{id: $id}')" | jq -c '.data.issue // empty')
    fi
  fi

  if [ -n "$LIN_MATCHED" ] && [ "$LIN_MATCHED" != "null" ]; then
    LIN_ISSUE_ID=$(echo "$LIN_MATCHED" | jq -r '.id')
    LIN_TEAM_ID=$(echo "$LIN_MATCHED" | jq -r '.team.id')
    LIN_CURRENT_LABELS=$(echo "$LIN_MATCHED" | jq -c '[.labels.nodes[].id]')

    # Resolve label IDs for this team
    LIN_LABELS_JSON=$(linear_gql 'query($teamId: String!) {
      issueLabels(filter: { team: { id: { eq: $teamId } } }) { nodes { id name } }
    }' "$(jq -cn --arg t "$LIN_TEAM_ID" '{teamId: $t}')")

    LIN_IN_PROG_BY_AGENT_ID=$(echo "$LIN_LABELS_JSON" | jq -r \
      '.data.issueLabels.nodes[] | select(.name | ascii_downcase == "in progress by agent") | .id')
    LIN_READY_HUMAN_ID=$(echo "$LIN_LABELS_JSON" | jq -r \
      '.data.issueLabels.nodes[] | select(.name | ascii_downcase == "ready for human review") | .id')

    if [ -z "$LIN_READY_HUMAN_ID" ]; then
      echo "WARNING: 'Ready for human review' label not found in Linear for team $LIN_TEAM_ID — skipping Linear label update"
    else
      # Remove "In Progress by agent", add "Ready for human review"
      LIN_NEW_LABELS=$(echo "$LIN_CURRENT_LABELS" | jq -c \
        --arg rm "$LIN_IN_PROG_BY_AGENT_ID" --arg add "$LIN_READY_HUMAN_ID" \
        '[.[] | select(. != $rm)] + [$add]')

      linear_gql 'mutation($id: String!, $labelIds: [String!]!) {
        issueUpdate(id: $id, input: { labelIds: $labelIds }) { success }
      }' "$(jq -cn --arg id "$LIN_ISSUE_ID" --argjson l "$LIN_NEW_LABELS" '{id:$id,labelIds:$l}')"
    fi
  else
    echo "WARNING: Could not find Linear issue for branch $BRANCH — skipping Linear update; continuing with GitHub promotion"
  fi
  ```

  **GitHub:** `gh pr edit <NUMBER> --repo "$REPO" --add-label "Ready for human review" --add-reviewer "$GH_USER"` (create the label first if it does not exist)

### A7. Finish PR cycle

On every non-failure outcome (promoted or skipped), remove the worktree so the PR is eligible for re-selection next cycle:

```bash
cd "$REPO_PATH"
git worktree remove "$WORKTREES_DIR/${BRANCH//\//-}"
```

Report: PR URL, threads addressed, conflicts fixed, promotion result (promoted / skipped — and why).

---

## Phase B — Issue Implementation

### B1. Find the oldest ready issue

Resolve your Linear user ID and find the oldest assigned ready issue in one pass:

```bash
# Get current user ID
LINEAR_USER_ID=$(linear_gql 'query { viewer { id } }' | jq -r '.data.viewer.id')

# List issues labeled "Ready for agent" assigned to me, oldest first
B1_JSON=$(linear_gql 'query($assigneeId: ID!) {
  issues(
    filter: {
      labels: { name: { eqIgnoreCase: "Ready for agent" } }
      assignee: { id: { eq: $assigneeId } }
      state: { type: { nin: ["completed", "cancelled"] } }
    }
    orderBy: createdAt
    first: 10
  ) {
    nodes {
      id identifier title branchName
      state { id name }
      labels { nodes { id name } }
      team { id }
    }
  }
}' "$(jq -cn --arg a "$LINEAR_USER_ID" '{assigneeId: $a}')")

B1_COUNT=$(echo "$B1_JSON" | jq '.data.issues.nodes | length')
[ "$B1_COUNT" -eq 0 ] && { echo "No issues ready"; exit 0; }

# Take the oldest (first result)
ISSUE_ID=$(echo "$B1_JSON"        | jq -r '.data.issues.nodes[0].id')
ISSUE_IDENTIFIER=$(echo "$B1_JSON" | jq -r '.data.issues.nodes[0].identifier')
ISSUE_TITLE=$(echo "$B1_JSON"     | jq -r '.data.issues.nodes[0].title')
BRANCH=$(echo "$B1_JSON"          | jq -r '.data.issues.nodes[0].branchName')
TEAM_ID=$(echo "$B1_JSON"         | jq -r '.data.issues.nodes[0].team.id')
CURRENT_LABEL_IDS=$(echo "$B1_JSON" | jq -c '[.data.issues.nodes[0].labels.nodes[].id]')
```

If there are none assigned to you, output `No issues ready` and STOP.

### B2. Claim the issue

Resolve label and state IDs for the team, then update the issue atomically:

```bash
# Resolve label IDs (case-insensitive) for this team
B2_LABELS_JSON=$(linear_gql 'query($teamId: String!) {
  issueLabels(filter: { team: { id: { eq: $teamId } } }) { nodes { id name } }
}' "$(jq -cn --arg t "$TEAM_ID" '{teamId: $t}')")

READY_FOR_AGENT_ID=$(echo "$B2_LABELS_JSON" | jq -r \
  '.data.issueLabels.nodes[] | select(.name | ascii_downcase == "ready for agent") | .id')
IN_PROGRESS_BY_AGENT_ID=$(echo "$B2_LABELS_JSON" | jq -r \
  '.data.issueLabels.nodes[] | select(.name | ascii_downcase == "in progress by agent") | .id')

# Resolve "In Progress" workflow state ID for this team
B2_STATES_JSON=$(linear_gql 'query($teamId: String!) {
  workflowStates(filter: { team: { id: { eq: $teamId } } }) { nodes { id name } }
}' "$(jq -cn --arg t "$TEAM_ID" '{teamId: $t}')")

IN_PROGRESS_STATE_ID=$(echo "$B2_STATES_JSON" | jq -r \
  '.data.workflowStates.nodes[] | select(.name | ascii_downcase == "in progress") | .id')

# Compute new label set: remove "Ready for agent", add "In Progress by agent"
NEW_LABEL_IDS=$(echo "$CURRENT_LABEL_IDS" | jq -c \
  --arg rm "$READY_FOR_AGENT_ID" --arg add "$IN_PROGRESS_BY_AGENT_ID" \
  '[.[] | select(. != $rm)] + [$add]')

# Update issue: set state to "In Progress" and swap labels
linear_gql 'mutation($id: String!, $stateId: String!, $labelIds: [String!]!) {
  issueUpdate(id: $id, input: { stateId: $stateId, labelIds: $labelIds }) { success }
}' "$(jq -cn --arg id "$ISSUE_ID" --arg s "$IN_PROGRESS_STATE_ID" --argjson l "$NEW_LABEL_IDS" \
  '{id:$id,stateId:$s,labelIds:$l}')"
```

### B3. Create a worktree

Use `$BRANCH` already captured in B1 (Linear's `branchName` field). Then:

```bash
DIR="$WORKTREES_DIR/${BRANCH//\//-}"
# A leftover dir means a prior crashed cycle — stop rather than clobber it.
[ -e "$DIR" ] && { echo "Worktree $DIR already exists (leftover from a prior cycle) — stopping"; exit 0; }
git -C "$REPO_PATH" fetch origin main:main
git -C "$REPO_PATH" worktree add -b "$BRANCH" "$DIR" main
cd "$DIR"
```

Do ALL subsequent implementation work with the shell cwd inside `$DIR`. Every git command (including `git push`) must run from `$DIR`.

### B4. Implement the issue

Implement the change described in the issue, following repo conventions in `CLAUDE.md`. Write or update tests as appropriate.

### B5. Quality gate (must pass before pushing)

```bash
pnpm ts:check
pnpm lint:fix
```

If these scripts are present, also run:

```bash
pnpm test:unit
pnpm test:acceptance:local
```

Only if `pnpm test:acceptance:local` script is not present and `pnpm test:acceptance` script is present, run:

```bash
pnpm test:acceptance
```

If either fails and you cannot fix it, STOP and report (leave the issue `In Progress by agent`).

### B6. Push and open the PR

```bash
git add -A
git commit -m "<concise message referencing the issue>"
git push -u origin "$BRANCH"
gh pr create --repo "$REPO" --base main --head "$BRANCH" \
  --title "<issue title>" \
  --body "Closes <ISSUE-IDENTIFIER>

<one-paragraph summary of the change>"
```

Capture the PR number from the `gh pr create` output (the URL ends in the number).

### B7. Drive CI to green (cap: 3 attempts)

```bash
gh pr checks <NUMBER> --watch --fail-fast
```

- Exit 0 → CI is green, go to B8.
- Reports `no checks reported on the 'HEAD' ref` → wait ~30s and retry once; if still none, treat as green.
- Non-zero → re-run the failing checks once before touching code:

  ```bash
  FAILED_RUN_ID=$(gh pr checks <NUMBER> --json name,conclusion,link \
    --jq '.[] | select(.conclusion == "FAILURE") | .link' | grep -oE '[0-9]+$' | head -1)
  gh run rerun --failed "$FAILED_RUN_ID"
  gh pr checks <NUMBER> --watch --fail-fast
  ```

  If it passes on retry, treat as green (go to B8). If still failing → inspect and fix:

  ```bash
  gh pr checks <NUMBER>
  gh run view <run-id> --log-failed
  git add -A && git commit -m "fix: address CI failure" && git push origin "$BRANCH"
  ```

  Re-run the watch. After 3 failed fix attempts, STOP and report (leave the issue `In Progress by agent`).

### B8. Finish implementation cycle

```bash
cd "$REPO_PATH"
git worktree remove "$WORKTREES_DIR/${BRANCH//\//-}"
```

Output a summary: issue identifier, PR URL, final CI status. Do NOT tag `Ready for human review`.

Then **loop back to Phase A** from A1 — select and process the next open PR before stopping.

---

## Failure handling

On any unrecoverable failure: leave the Linear issue labeled `In Progress by agent`, keep the worktree for debugging, and report exactly what failed and where. Never revert an issue back to `Ready for agent`.
