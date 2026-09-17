#!/usr/bin/env bash
# agent-build — the build entrypoint. The orchestrator execs this in a container booted from the
# builder image; its stdout IS the build stream (claude `--output-format stream-json`), consumed
# live by whatever drives the build. It must NOT POST a callback.
#
# Env injected per-sandbox by the orchestrator at dispatch (+ secrets):
#   BRIEF_B64 ACCEPTANCE_CRITERIA_B64 ACCEPTANCE_CRITERIA_IDS_B64 PRODUCT_SPEC_B64
#   REVIEW_FEEDBACK_B64  (base64 — decoded below)
#   REPO_URL BASE_BRANCH(=the milestone branch) BRANCH(=assignment/<slug>-<id>) ASSIGNMENT_ID SESSION_ID
#   GITHUB_TOKEN MODEL MAX_BUDGET_USD  + ONE of: CLAUDE_CODE_OAUTH_TOKEN | ANTHROPIC_API_KEY
#
# It emits two control lines the orchestrator folds into finalize state:
#   {"type":"agent_coverage","coverage":[…]}  — the per-criterion claim (gated below)
#   {"type":"agent_commit","sha":"…"}          — the delivered commit, only once the push is verified
set -euo pipefail

: "${REPO_URL:?REPO_URL required}"
: "${BRANCH:?BRANCH required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
# claude authenticates with EITHER a Claude-subscription OAuth token (preferred, billed to the
# subscription) OR the metered API key. DispatchBuild injects exactly one; require at least one here.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "FATAL: set CLAUDE_CODE_OAUTH_TOKEN (claude subscription) or ANTHROPIC_API_KEY" >&2
  exit 1
fi
BASE_BRANCH="${BASE_BRANCH:-main}"
MODEL="${MODEL:-claude-opus-5}"
APP_DIR=/workspace/app
# The coverage artifact lives OUTSIDE the checkout, deliberately. It is evidence ABOUT the build, not
# a product file, and `git add -A` below stages everything in the repo — so a path inside $APP_DIR
# would commit the agent's own claim about its work into the product it just wrote.
COVERAGE_JSON=/workspace/coverage.json

# The free-text context fields (brief, criteria, spec, rework feedback) arrive base64-encoded with a
# _B64 suffix — DispatchBuild encodes them so LLM-authored text (em-dashes, smart quotes, arrows) can
# be injected as env values without tripping the sandbox VMM's non-ASCII guard. Decode them back to
# the bare names used when assembling the prompt below. The `:-` guards keep `set -u` happy when a
# field is absent; an empty/unset value decodes to "" and the downstream `${VAR:-default}` still fires.
decode_b64() { [ -n "${1:-}" ] && printf '%s' "$1" | base64 --decode || true; }
BRIEF="$(decode_b64 "${BRIEF_B64:-}")"
ACCEPTANCE_CRITERIA="$(decode_b64 "${ACCEPTANCE_CRITERIA_B64:-}")"
PRODUCT_SPEC="$(decode_b64 "${PRODUCT_SPEC_B64:-}")"
REVIEW_FEEDBACK="$(decode_b64 "${REVIEW_FEEDBACK_B64:-}")"

# `<id>\t<text>` per line — the same criteria as ACCEPTANCE_CRITERIA, each carrying the stable id the
# orchestrator keys its rows by.
#
# **These ids are ECHOED, never computed.** `Invoker.Judgment.Criteria.id/1` is
# `sha256(text) | hex | first 12`, which `sha256sum | cut -c1-12` reproduces EXACTLY on clean ASCII —
# which is what makes recomputing them dangerous rather than merely redundant. It would pass the first
# test and then drift on the first criterion carrying a smart quote, a trailing space, a different
# unicode normalisation, or a `- ` prefix stripped one character wide. A drifted id does not read as a
# bug on either side; it reads as *the agent invented a criterion*, and a correct build is rejected for
# dishonesty. So the gate below does set membership against this list and no hashing at all.
#
# The text half is escaped by the orchestrator so it cannot forge a line boundary here. Do not
# un-escape it: a forged line would contribute a junk id to the very set membership is tested against,
# which INVERTS the gate rather than weakening it.
ACCEPTANCE_CRITERIA_IDS="$(decode_b64 "${ACCEPTANCE_CRITERIA_IDS_B64:-}")"
CRITERION_IDS="$(printf '%s' "$ACCEPTANCE_CRITERIA_IDS" | cut -f1 | sed '/^$/d')"

log() { printf '\n=== %s ===\n' "$1"; }

log "starting postgres"
start-postgres

log "configuring git"
# Credential helper feeds the scoped token without baking it into the remote URL.
git config --global credential.helper '!f() { echo username=x-access-token; echo "password=${GITHUB_TOKEN}"; }; f'
git config --global user.email "agent@local"
git config --global user.name "build-agent"
git config --global init.defaultBranch main

# The host already scaffolded `main` (template fetch + rename + initial push happen on the host, NOT
# in this VM), so the remote is always populated. A prior attempt — a failed build, or a
# `request_changes` rework — may have already pushed commits to $BRANCH; REUSE them. Continuing on
# top keeps the committed plans (`.claude/plans/**`) and partial implementation instead of rebuilding
# from scratch (too expensive to throw away), and keeps the post-commit push a fast-forward — a
# fresh-from-main branch would non-ff-reject against the prior attempt's remote HEAD and silently
# drop this attempt's commits. No existing branch → branch fresh from $BASE_BRANCH.
rm -rf "$APP_DIR"
if git clone --branch "$BRANCH" "$REPO_URL" "$APP_DIR" 2>/dev/null; then
  log "reusing existing ${BRANCH} (continuing a prior attempt)"
  cd "$APP_DIR"
else
  log "cloning ${REPO_URL} (${BASE_BRANCH}); creating ${BRANCH}"
  git clone --branch "$BASE_BRANCH" "$REPO_URL" "$APP_DIR"
  cd "$APP_DIR"
  git checkout -b "$BRANCH"
fi

log "bridging agent memory"
# Claude Code's auto-memory lives OUTSIDE the repo — keyed by cwd at
# /root/.claude/projects/-workspace-app/memory/ — so the lessons the agent captures in the
# compound phase die with this container. Symlink that path into the repo (.claude/memory, not
# gitignored → committed by the `git add -A` below): prior builds' lessons load at session start
# (Claude Code injects MEMORY.md), and new ones round-trip through git to the next attempt.
mkdir -p "$APP_DIR/.claude/memory" /root/.claude/projects/-workspace-app
rm -rf /root/.claude/projects/-workspace-app/memory
ln -s "$APP_DIR/.claude/memory" /root/.claude/projects/-workspace-app/memory

log "installing dependencies"
mix deps.get
# `mix setup` runs the generated app's own setup alias (deps, ash.setup, assets). Fall back to the
# pieces if the app has no `setup` alias.
mix setup || (mix ash.setup && mix assets.setup && mix assets.build)

log "wiring git hooks"
# post-commit: push every commit as it lands, so progress survives a killed container. `/phx:full`
# commits per task BY DESIGN — its rollback model is task-level checkpoints (see the skill's
# references/safety-recovery.md) — so this fires often, and a build that dies at 80% keeps its 80%.
# The next attempt reuses the branch (see the clone above) and continues from there.
#
# stdout stays suppressed (the credential helper feeds the token over stdout), but stderr is now
# CAPTURED and printed only on failure. The old fire-and-forget `2>&1 || true` swallowed the reason
# entirely — and now that pre-push can legitimately REFUSE a push, silence would hide a secret leak.
cat > .git/hooks/post-commit <<'HOOK'
#!/usr/bin/env bash
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" = "HEAD" ] && exit 0
err="$(git push -u origin "$branch" 2>&1 >/dev/null)" ||
  printf 'WARN: post-commit push failed: %s\n' "$err" >&2
HOOK
chmod +x .git/hooks/post-commit

# pre-push: the secret gate. It MUST live here rather than in the finalize block. The agent commits
# freely and post-commit pushes each commit immediately, so a one-shot scan of the STAGED diff at the
# end only ever saw what the agent had left uncommitted — meaning the more the agent committed, the
# less the gate covered. As a hook it runs on every push: the agent's, post-commit's, and finalize's.
#
# Scans the whole tracked tree at HEAD instead of a commit range: no ref-math edge cases (branch
# creation, force-update, first push) and it cannot under-scan. `git grep` ignores untracked and
# gitignored files, which is exactly right — only what is actually being delivered gets scanned.
cat > .git/hooks/pre-push <<'HOOK'
#!/usr/bin/env bash
if git grep -IqE 'gh[posru]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]+|sk-ant-[A-Za-z0-9-]+' HEAD; then
  echo "FATAL: token-shaped string in tracked files — refusing to push" >&2
  exit 1
fi
HOOK
chmod +x .git/hooks/pre-push

log "running claude"
# Headless agentic build via the plugin's **/phx:full** workflow (plan → work → verify → review →
# compound, with specialist agents + Iron-Law gates). stream-json (the worker parses it) requires
# --verbose with -p; the plugin loads from the repo's committed .claude/settings.json enabledPlugins.
# /phx:full is designed to run autonomously end-to-end (it should NOT stall on a plan-approval prompt).
#
# Permissions: `bypassPermissions` auto-approves EVERY tool (Bash, MCP, …), not just edits. The old
# `acceptEdits` auto-approved file writes ONLY — so `mix`/`git`/chained-bash were all denied with no
# interactive approver, and the agent built blind (couldn't run ash.codegen/tests/precommit or commit).
# claude refuses bypassPermissions as root unless IS_SANDBOX=1 (its root-guard escape) — true here: we
# are a libkrun microVM, an actual sandbox.
#
# The context pack (product spec + acceptance criteria, assembled by DispatchBuild) goes in the
# assignment description. We deliberately do NOT pass a "what already exists" digest — /phx:full
# inspects the cloned codebase to learn the current state. Acceptance-test pass in CI is the thesis
# metric, so the tests are the contract: a genuine passing test per criterion, never weakened.

# Rework feedback (REVIEW_FEEDBACK, set by request_changes) goes INSIDE the description so the
# prompt still starts with the /phx:full command.
FEEDBACK_SECTION=""
if [ -n "${REVIEW_FEEDBACK:-}" ]; then
  FEEDBACK_SECTION="## Reviewer feedback (address this FIRST)
${REVIEW_FEEDBACK}
"
fi

# The coverage artifact's contract. Omitted entirely when the assignment has no acceptance criteria —
# there is nothing to claim, and asking for an empty file invites the agent to invent entries for it.
# The empty control line is still emitted in that case (see "emitting coverage"), so "nothing to
# claim" stays distinguishable from "claimed nothing".
COVERAGE_SECTION=""
if [ -n "$CRITERION_IDS" ]; then
  COVERAGE_SECTION="## Coverage report — REQUIRED, and it is checked

Before you finish, write a JSON array to ${COVERAGE_JSON} with **exactly one entry per criterion
id below**, using the ids verbatim:

[{\"criterion_id\":\"<id from the list>\",\"coverage\":\"covered|partial|not_covered\",
  \"proof\":\"path/to/test_file.exs:LINE\",\"note\":\"…\"}]

- \`criterion_id\` — copy it from the list. Do not compute, shorten or invent one.
- \`coverage\` — exactly one of \`covered\`, \`partial\`, \`not_covered\`. Nothing else.
- \`proof\` — REQUIRED for \`covered\`: the test that verifies it, as a repository-relative
  \`path\` or \`path:line\` that resolves in this checkout. Not a description of a test.
- \`note\` — REQUIRED for \`partial\` and \`not_covered\`: name the gap, or say why not.

Report honestly. \`not_covered\` with a reason is a real answer and a useful one; a \`covered\`
claim whose proof does not resolve is worse than no claim, and it will be rejected. Do not delete
or weaken a test to make a claim true.

### The criteria and their ids

${ACCEPTANCE_CRITERIA_IDS}
"
fi

PROMPT="/phx:full Implement an assignment in this existing Phoenix/Ash + LiveVue app, following the
project's conventions (CLAUDE.md + the loaded skills). Inspect the existing codebase to understand
what is already built before adding to it.

You are running headless — there is no user to answer questions. Never stop to present options or
wait for input; where the workflow asks the user to choose (e.g. discovery's workflow depth),
decide yourself from the assignment's complexity and continue. On a fresh scaffold with no existing
domains, the codebase-patterns and library research agents may be skipped when there is nothing
for them to analyze — note the skip in the plan instead.

${FEEDBACK_SECTION}## Product context (the whole product this assignment is part of)
${PRODUCT_SPEC:-(none provided)}

## Assignment to build
${BRIEF:-(no brief provided)}

## Acceptance criteria — satisfy EVERY one with a genuine passing automated test
${ACCEPTANCE_CRITERIA:-(none specified)}

Each criterion needs a real test (ExUnit / Phoenix.LiveViewTest, or LiveVue.Test for Vue surfaces)
that actually verifies it — never weaken or delete a test to make it pass.

${COVERAGE_SECTION}"

# --- budget: `--max-budget-usd` is PER INVOCATION, so two calls must not each get the full cap ---
#
# The coverage gate below can run the agent a second time, and a naive re-prompt would hand it a fresh
# full budget — doubling a ceiling a human set, silently. The retry's share is RESERVED out of the
# total up front, so the sum is bounded by construction rather than discovered afterwards. Identical
# arithmetic to `entrypoint-audit.sh` / `entrypoint-retro.sh`.
#
# The cost this carries and the audit path does not: 20% off a BUILD budget is 20% less
# implementation, on every build, to insure against a coverage file the gate usually passes first
# time. Taken anyway, because the alternative is the one build stage that can exceed the budget
# `Invoker.Plan.Assignment.Changes.DispatchBuild` derives from the pipeline — and if 80% is too tight,
# the fix is to raise that declared number once, visibly, rather than to let this script quietly
# overspend. `--continue` is what makes 20% enough: the retry is a follow-up turn rewriting a JSON
# file, not a second build.
FIRST_BUDGET=""
RETRY_BUDGET=""
if [ -n "${MAX_BUDGET_USD:-}" ]; then
  FIRST_BUDGET="$(awk -v b="$MAX_BUDGET_USD" 'BEGIN { printf "%.4f", b * 0.8 }')"
  RETRY_BUDGET="$(awk -v b="$MAX_BUDGET_USD" 'BEGIN { printf "%.4f", b * 0.2 }')"
fi

# One headless agent invocation. $1 = prompt, $2 = budget (may be empty), $3+ = extra flags.
#
# Permissions: `bypassPermissions` auto-approves EVERY tool (Bash, MCP, …), not just edits. The old
# `acceptEdits` auto-approved file writes ONLY — so `mix`/`git`/chained-bash were all denied with no
# interactive approver, and the agent built blind (couldn't run ash.codegen/tests/precommit or commit).
# claude refuses bypassPermissions as root unless IS_SANDBOX=1 (its root-guard escape) — true here: we
# are a container the orchestrator owns.
#
# `set +e` around the call: an agent failure must NOT abort the script — we still want to persist
# artifacts and emit the SHA so the control plane can recover (the dead-end scratchpad survives for
# the next attempt).
run_claude() {
  local prompt="$1" budget="$2"
  shift 2
  local budget_args=""
  [ -n "$budget" ] && budget_args="--max-budget-usd $budget"

  set +e
  # shellcheck disable=SC2086
  IS_SANDBOX=1 claude --print "$prompt" \
    --output-format stream-json --verbose \
    --permission-mode bypassPermissions \
    --model "$MODEL" \
    $budget_args "$@"
  set -e
}

# Build provenance — the half of "what actually ran" that is NOT reconstructible from Postgres
# afterwards. MODEL/MAX_BUDGET_USD are orchestrator config read at dispatch time (change the config
# and every past build becomes unattributable, and a `--max-budget-usd` stop is otherwise
# indistinguishable from a clean finish — the result event carries the spend, never the cap); the CLI
# version decides whether `/phx:full` resolves at all (Dockerfile pins BELOW 2.1.216, where plugin
# skills got re-namespaced and the command silently becomes literal prose); the base SHA pins WHICH
# template — which CLAUDE.md, which entrypoint — this build forked from.
#
# Emitted AFTER `=== running claude ===` on purpose: the orchestrator collapses every line before
# that marker into a single `setup` stream row that downstream retrospection drops — so a banner
# printed with the other setup logs would never reach the assessment run that needs it.
#
# Free text is logged as byte counts + a prompt digest, never verbatim: the text already lives in
# assignments.brief / acceptance_criteria / milestones.spec, and those columns are mutable — the digest
# is what proves whether this build ran the prompt they describe today. NEVER dump the environment
# wholesale: GITHUB_TOKEN and the agent credential sit in it, and build_events is rendered to the
# console, stored unencrypted, and fed VERBATIM to the assess LLM, while this repo's only secret gate
# scans the staged git diff — a token echoed here bypasses it entirely.
log "build provenance"
PROMPT_SHA="$(printf '%s' "$PROMPT" | sha256sum 2>/dev/null | cut -c1-12 || true)"
printf 'agent:    %s\n' "$(claude --version 2>/dev/null || echo unknown)"
printf 'model:    %s\n' "$MODEL"
# Both halves of the split, because "the build stopped at 80% of the cap I set" is otherwise an
# unexplainable budget stop — the result event carries the spend, never the cap or its division.
printf 'budget:   %s (build %s + coverage retry %s)\n' \
  "${MAX_BUDGET_USD:-uncapped}" "${FIRST_BUDGET:-uncapped}" "${RETRY_BUDGET:-uncapped}"
printf 'depth:    %s\n' "${CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH:-default}"
printf 'branch:   %s @ %s\n' "$BRANCH" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
printf 'base:     %s @ %s\n' "$BASE_BRANCH" \
  "$(git rev-parse --short "origin/${BASE_BRANCH}" 2>/dev/null || echo unknown)"
printf 'context:  brief=%sB criteria=%sB spec=%sB feedback=%sB\n' \
  "${#BRIEF}" "${#ACCEPTANCE_CRITERIA}" "${#PRODUCT_SPEC}" "${#REVIEW_FEEDBACK}"
printf 'prompt:   sha256=%s\n' "${PROMPT_SHA:-unavailable}"
# One line per plugin, not the 24-line pretty-printed blocks: these land AFTER the setup marker, so
# every line is its own persisted `build_events` row and goes verbatim into the assess run's input.
# `disabled` here is the signal that matters — the plugins load from the repo's committed
# .claude/settings.json `enabledPlugins`, so a disabled elixir-phoenix means the whole /phx:* +
# Iron-Law layer silently isn't there.
claude plugin list 2>/dev/null | awk '
  /❯/        { name=$2 }
  /Version:/  { ver=$2 }
  /Status:/   { print "plugin:   " name " " ver " " (/disabled/ ? "disabled" : "enabled") }
' || true

run_claude "$PROMPT" "$FIRST_BUDGET"

# --- the coverage gate: validate, re-prompt ONCE, then report what survives ---
#
# Sibling of the findings gates in `entrypoint-audit.sh` / `entrypoint-retro.sh`, and it enforces the
# same rule: a claim must point at something that exists. It differs from them in three ways, each of
# which is a consequence of what a BUILD is, and copying either sibling verbatim would get all three
# wrong.
#
# 1. **It is NOT fatal.** Audit's gate exits 1, because a scan that cannot say what it found has not
#    found nothing, and there is no downstream representation of a failed scan. A build has one:
#    Invoker manufactures an `:unknown` row per criterion and records `coverage_reported: false`, so
#    "the claim never arrived" is a state the system can already express honestly. Aborting here would
#    instead discard working code — plus the dead-end scratchpad that makes the next attempt cheaper —
#    over an evidence artifact, at the irreversible end of the pipeline. That is the same trade this
#    script already makes for a red `mix precommit` two blocks below.
#
# 2. **A surviving partial claim is still emitted.** After a failed re-prompt, anything that parses as
#    an array goes out as-is: Invoker's `Coverage.normalize/2` keeps the valid entries and drops and
#    COUNTS the rest onto `Run.coverage_drops`. Discarding a file because two of five entries are bad
#    would throw away three real claims to punish two. Only an unparseable file emits nothing at all.
#
# 3. **It runs BEFORE `mix precommit` and the commit block.** The re-prompt can legitimately touch the
#    tree (correcting a claim may mean correcting the code it names), and a gate placed after the
#    commit produces edits nothing stages — and, worse, leaves a pushed branch orphaned if it fails.
#
# There is NO empty-array fallback anywhere in here. That line — `printf '[]'` — is the exact failure
# this whole artifact exists to remove: it turns a build that could not report on its work into a
# build that reports having nothing to report.
validate_coverage() {
  local rows errs=0 seen="" i kind cid coverage proof note file line lines

  if [ ! -f "$COVERAGE_JSON" ]; then
    echo "no coverage file was written at ${COVERAGE_JSON}"
    return 1
  fi
  if ! jq -e 'type == "array"' "$COVERAGE_JSON" >/dev/null 2>&1; then
    echo "${COVERAGE_JSON} is not a JSON array"
    return 1
  fi

  # One extraction pass, then validate in bash — the audit gate's split, for its reasons. `clean`
  # strips CONTROL characters from every field, which is what makes a single delimiter sufficient:
  # agent-written JSON may legally carry a newline inside a note, and an unescaped one would forge a
  # field boundary and shift every value after it, reporting a fault in the entry beside the real one.
  # The delimiter is US (0x1f) and NOT a tab, because tab is an IFS *whitespace* character — bash
  # collapses runs of them and drops leading ones, so an empty `coverage` would slide `proof` into its
  # place and complain about the wrong field. `clean` has already removed every 0x1f from the data.
  rows="$(jq -r '
    def clean: (. // "") | tostring | gsub("[[:cntrl:]]"; " ");
    to_entries[]
    | .key as $i
    | .value as $c
    | if ($c | type) == "object" then
        [($i | tostring), "object",
         ($c.criterion_id | clean), ($c.coverage | clean),
         ($c.proof | clean), ($c.note | clean)]
      else
        [($i | tostring), "other", "", "", "", ""]
      end
    | join("\u001f")' "$COVERAGE_JSON")"

  while IFS=$'\037' read -r i kind cid coverage proof note; do
    [ -z "$kind" ] && continue

    if [ "$kind" != "object" ]; then
      echo "entry $i: not a JSON object"
      errs=$((errs + 1))
      continue
    fi

    # --- the id: SET MEMBERSHIP against the injected list, with no hashing at all ---
    #
    # `grep -Fxq` is the whole check: fixed string, whole line, so it cannot match a prefix, a
    # substring or a regex metacharacter. The `case " a b c " in *" $x "*)` idiom that both finding
    # gates once used is what this deliberately avoids — any run of adjacent whitelist words passed
    # it, and here the equivalent hole would admit a fabricated id that happens to contain a real one.
    cid="$(printf '%s' "$cid" | tr -d '[:space:]')"
    if [ -z "$cid" ]; then
      echo "entry $i: criterion_id is required — copy one from the list in the prompt"
      errs=$((errs + 1))
      continue
    elif ! printf '%s\n' "$CRITERION_IDS" | grep -Fxq "$cid"; then
      echo "entry $i: criterion_id \"$cid\" is not one of this assignment's criteria — use the ids exactly as given, and do not compute them"
      errs=$((errs + 1))
      continue
    elif printf '%s\n' "$seen" | grep -Fxq "$cid"; then
      echo "entry $i: criterion_id \"$cid\" is claimed twice — one entry per criterion"
      errs=$((errs + 1))
      continue
    fi
    seen="${seen}${cid}
"

    # Closed enum, matched by alternation on the VALUE. `:unknown` is deliberately not accepted: it is
    # Invoker's own marker for a criterion the build never mentioned, and an agent filing it would be
    # filing the did-not-report state as though it were a considered answer.
    case "$coverage" in
      covered | partial | not_covered) ;;
      *)
        echo "entry $i ($cid): coverage \"$coverage\" must be covered, partial or not_covered"
        errs=$((errs + 1))
        ;;
    esac

    # A `partial` or `not_covered` with no note is the shape that reads as considered when nobody
    # knows whether the criterion was opened — `LensCoverage`'s "unknown with a blank reason", one
    # tier down. The gate is the cheap place to ask, because the agent is still alive.
    case "$coverage" in
      partial | not_covered)
        if [ -z "$(printf '%s' "$note" | tr -d '[:space:]')" ]; then
          echo "entry $i ($cid): $coverage requires a note naming the gap or the reason"
          errs=$((errs + 1))
        fi
        ;;
    esac

    if [ "$coverage" = "covered" ] && [ -z "$(printf '%s' "$proof" | tr -d '[:space:]')" ]; then
      echo "entry $i ($cid): covered requires a proof — the test that verifies it, as path or path:line"
      errs=$((errs + 1))
      continue
    fi

    # --- the proof: a path that RESOLVES in this checkout ---
    #
    # Checked for every state that supplies one, not only for `covered`: a wrong proof on a partial
    # claim is still a wrong proof, and it is the half a reader would trust.
    #
    # The audit gate asks `git ls-files --error-unmatch` here. **That exact test is wrong in a build**
    # and copying it would reject correct proofs: an audit reads a branch where everything is already
    # committed, while this runs before the commit block, so a test the agent just wrote is not yet
    # tracked. So membership is enforced structurally instead — no leading `/`, no `..` component —
    # and then the file simply has to exist. Deliberately NOT a free-text "test name": an
    # unvalidatable proof is prose again, which is what this artifact exists to replace.
    [ -z "$(printf '%s' "$proof" | tr -d '[:space:]')" ] && continue

    file="${proof%%:*}"
    line="${proof#"$file"}"
    line="${line#:}"

    if [ "${file#/}" != "$file" ]; then
      echo "entry $i ($cid): proof \"$proof\" is an absolute container path — cite it relative to the repository root"
      errs=$((errs + 1))
    elif printf '%s' "/$file/" | grep -q '/\.\./'; then
      # A `..` COMPONENT, not the substring: `a..b.ex` is a legal filename and must not be rejected.
      # Wrapping in slashes is what makes a leading or trailing `..` match the same pattern.
      echo "entry $i ($cid): proof \"$proof\" escapes the repository — cite a path inside the checkout"
      errs=$((errs + 1))
    elif [ ! -f "$file" ]; then
      echo "entry $i ($cid): proof \"$proof\" does not resolve — \"$file\" is not a file in this checkout"
      errs=$((errs + 1))
    elif [ -n "$line" ]; then
      if ! printf '%s' "$line" | grep -qE '^[1-9][0-9]{0,9}$'; then
        echo "entry $i ($cid): proof line \"$line\" must be a positive integer"
        errs=$((errs + 1))
      else
        # `awk END{print NR}`, not `wc -l`: a file whose last line has no trailing newline is
        # undercounted by one by `wc`, which would reject a correct citation of its final line.
        lines="$(awk 'END { print NR }' "$file")"
        if [ "$line" -gt "$lines" ]; then
          echo "entry $i ($cid): proof line $line is past the end of \"$file\" (${lines} lines)"
          errs=$((errs + 1))
        fi
      fi
    fi
  done <<< "$rows"

  # --- completeness: every injected criterion got an answer ---
  #
  # The half no single entry can enforce, and the recoverable copy of it: Invoker re-checks this at
  # ingest against LIVE criteria (the authoritative version, since criteria can change after
  # dispatch), where the only available response is to manufacture an `:unknown` row. Here the agent
  # is still alive and can simply be asked.
  while IFS= read -r cid; do
    [ -z "$cid" ] && continue
    if ! printf '%s\n' "$seen" | grep -Fxq "$cid"; then
      echo "criterion $cid has no entry — report on every criterion, including the ones you did not cover"
      errs=$((errs + 1))
    fi
  done <<< "$CRITERION_IDS"

  [ "$errs" -eq 0 ]
}

if [ -n "$CRITERION_IDS" ]; then
  log "validating coverage"
  COVERAGE_ERRORS="/workspace/coverage-errors.txt"
  if ! validate_coverage > "$COVERAGE_ERRORS" 2>&1; then
    echo "WARN: coverage report failed validation; re-prompting once" >&2
    sed 's/^/  /' "$COVERAGE_ERRORS" >&2

    # `--continue` resumes THIS conversation in this directory, so the agent still holds its plan and
    # its implementation and only has to correct the report. A fresh `--print` would be a second build
    # at a fifth of the budget, which is how a re-prompt makes output worse instead of better.
    run_claude "Your coverage report ${COVERAGE_JSON} failed validation:

$(cat "$COVERAGE_ERRORS")

Rewrite ${COVERAGE_JSON} so every entry satisfies the contract. Do NOT invent a claim to fill a gap
and do NOT weaken or delete a test to make a claim true — a criterion you did not finish should be
reported as partial or not_covered with a note, which is a real and useful answer. If a proof path
was wrong, correct it against the actual checkout." "$RETRY_BUDGET" --continue

    if ! validate_coverage > "$COVERAGE_ERRORS" 2>&1; then
      # Not fatal — see (1) above. What survives is still emitted; Invoker counts what does not.
      echo "WARN: coverage report still invalid after one re-prompt — emitting what parses; the orchestrator will count the rest as drops" >&2
      sed 's/^/  /' "$COVERAGE_ERRORS" >&2
    fi
  fi
fi

log "emitting coverage"
# Deterministic emission — read the agent-written file and wrap it. **Never trust the model to print
# the control line itself**: the same discipline `entrypoint-audit.sh` states for findings, and it
# matters more here, because one forged line claiming `covered` for every criterion makes a reviewer's
# screen say the work is done.
#
# The empty line for a criteria-less assignment is emitted deliberately. It is what keeps "there was
# nothing to claim" distinguishable from "the coverage stage never ran", which is the distinction
# `Run.coverage_reported` exists to carry.
if [ -z "$CRITERION_IDS" ]; then
  printf '{"type":"agent_coverage","coverage":[]}\n'
elif jq -e 'type == "array"' "$COVERAGE_JSON" >/dev/null 2>&1; then
  jq -c '{type: "agent_coverage", coverage: .}' "$COVERAGE_JSON"
else
  # No line at all, and no `[]` standing in for one. Invoker manufactures an `:unknown` row per
  # criterion and records `coverage_reported: false` — which says "this build did not report", where
  # an empty array would have said "this build reported nothing to say".
  echo "WARN: no parseable ${COVERAGE_JSON}; emitting no coverage line" >&2
fi

log "verifying the build"
# The agent is TOLD to reach a green `mix precommit` (see the prompt above), but nothing ENFORCED it:
# this script used to commit and push whatever tree the agent left behind. So a `--max-budget-usd`
# hard-stop mid-work, a `credo --strict` nit, or a broken SSR bundle only surfaced minutes later as a
# red CI check-run, on another machine. Run the SAME gate CI runs, here, while the container is warm.
#
# Ordering is load-bearing — this runs BEFORE the `git add -A` below, because two precommit steps are
# MUTATORS, not checks: bare `format` and `deps.unlock --unused` rewrite files and exit 0. In CI they
# rewrite an ephemeral checkout, so the fix is thrown away and the drift never lands in the repo.
# Running them here means the formatted tree is what gets committed.
#
# `assets.build` is NOT part of `precommit` — CI runs it as its own step — so a broken Vue/SSR bundle
# is invisible to the agent's own precommit loop. `&&` mirrors CI's step sequencing (a failed step
# aborts the job). It writes only to /priv/static, which is gitignored, so nothing extra gets staged.
#
# NON-FATAL by design. A red gate must NOT abort: the recovery model here is "persist artifacts and
# emit the SHA so the control plane can recover" (same reason the agent run is wrapped in `set +e`).
# Aborting would discard the agent's work AND the dead-end scratchpad that makes the next attempt
# cheaper — strictly worse than shipping a red commit. We report; CI still governs the state machine.
set +e
mix assets.build 2>&1 && mix precommit 2>&1
VERIFY_STATUS=$?
set -e
if [ "$VERIFY_STATUS" -eq 0 ]; then
  printf 'verify:   precommit GREEN\n'
else
  printf 'verify:   precommit RED (exit %s) — committing anyway; CI check-run confirms\n' "$VERIFY_STATUS"
fi

log "committing the build"
# WE own the commit — do NOT assume the agent committed. `/phx:full` commits per task by design, but
# that is the skill's convention, not a guarantee: a `--max-budget-usd` hard-stop can end the run
# mid-task with work still in the tree. This sweep is the backstop, not the primary path. Stage
# EVERYTHING it produced: assignment code, plans/scratchpad, and the memory bridged into .claude/memory.
# Nothing under .claude/ is gitignored in this template, so `git add -A` covers it all; the -f on
# .claude/plans is belt-and-suspenders in case a generated app ever grows a .claude ignore rule.
git add -A >/dev/null 2>&1 || true
[ -d .claude/plans ] && git add -f .claude/plans >/dev/null 2>&1 || true
[ -d .claude/memory ] && git add -f .claude/memory >/dev/null 2>&1 || true

# The secret gate used to live HERE, scanning `git diff --cached`. It moved to the pre-push hook
# above: the agent ran with a live GITHUB_TOKEN and LLM keys in env, and once it commits its own work
# (which /phx:full does per task) post-commit pushes it before this line is ever reached — so a
# staged-diff scan guarded only the leftovers. The hook catches every push, including this one.

if git diff --cached --quiet; then
  # Nothing staged. Two very different reasons — disambiguate by whether HEAD already moved past base:
  #  - Agent committed its own work: the EXPECTED path now that the prompt no longer talks it out of
  #    touching git. Working tree clean, HEAD ahead of base, post-commit already pushed each commit —
  #    the work IS delivered and the finalize push below just fast-forwards. NOT a failure; the old
  #    "nothing to deliver" WARN here was a false alarm.
  #  - Agent produced nothing at all: HEAD still equals base. Emit no agent_commit — a false SHA
  #    equal to base would sail through verify (CI green on scaffold) and blow up later at preview.
  #    The "no commits beyond base" guard in finalize then blocks the build, which is correct.
  if [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BASE_BRANCH" 2>/dev/null || true)" ]; then
    echo "WARN: agent produced no changes to commit — nothing to deliver" >&2
  else
    echo "note: agent committed its own work; delivering its commit(s)" >&2
  fi
else
  git commit -m "feat(agent): build ${ASSIGNMENT_ID:-assignment}" >/dev/null 2>&1 || true
fi

log "finalizing"
# Push and VERIFY the remote actually advanced. The post-commit hook's push is fire-and-forget
# (git ignores its exit code), so a failed push is otherwise SILENT — the whole reason a build can
# report a commit that never landed. Keep push output off the stream (the credential helper feeds
# the token over stdout), then compare local HEAD to origin/$BRANCH and only emit agent_commit
# when they match. A mismatch (or a branch with no commits beyond base) fails the build loudly.
#
# stderr is captured (stdout stays suppressed — credential helper) so the FATAL below can say WHY.
# Without it, a pre-push secret refusal is indistinguishable from a network failure: both surface
# only as "did not land", sending whoever reads it hunting the wrong problem.
PUSH_ERR="$(git push -u origin "$BRANCH" 2>&1 >/dev/null)" || true
SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse "origin/$BRANCH" 2>/dev/null || true)"

if [ -z "$REMOTE_SHA" ] || [ "$SHA" != "$REMOTE_SHA" ]; then
  echo "FATAL: build commit $SHA did not land on origin/$BRANCH (remote HEAD: ${REMOTE_SHA:-none})" >&2
  [ -n "$PUSH_ERR" ] && echo "push said: $PUSH_ERR" >&2
  exit 1
fi

if [ "$SHA" = "$(git rev-parse "origin/$BASE_BRANCH" 2>/dev/null || true)" ]; then
  echo "FATAL: $BRANCH has no commits beyond $BASE_BRANCH — nothing was built" >&2
  exit 1
fi

# Control line the orchestrator reads for the assignment's commit_sha.
printf '{"type":"agent_commit","sha":"%s"}\n' "$SHA"
