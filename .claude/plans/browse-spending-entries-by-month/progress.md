# Progress — Browse spending entries by month

**State:** COMPLETED · **Cycles used:** 1 of 10 · **Blockers:** 0

## Phases

| Phase | Status | Artifact |
|---|---|---|
| DISCOVERING | done | plan.md § Discovery summary |
| PLANNING | done | `plan.md`, `research/*-report.md` (2 agents) |
| WORKING | done | 9 files changed, +331 / −18 |
| VERIFYING | done | `mix precommit` green · `mix assets.build` green · QuickBEAM SSR smoke test |
| REVIEWING | done | `reviews/*.md` (3 agents) |

## Tasks

- [x] B1 `Spending.earliest_month/0` via `Ash.min(Entry, :date)`
- [x] B2 `Month.before?/2`
- [x] L1 `:earliest_month` assign
- [x] L2 `month_prop/3` gains `earliest`, nulls `prev` at the floor and `next` at the ceiling
- [x] L3 `select_month` refuses anything outside the navigable range (`navigable?/2`)
- [x] L4 `push_event("scroll_to_top", …)` on an accepted navigation only
- [x] L5 floor recomputed on every `load_month/1` (back-dated entries move it)
- [x] F1 `types.ts` — `prev` nullable, `earliest` added
- [x] F2 `MonthSwitcher.vue` — back arrow disabled on `prev === null`, `aria-live` on the label
- [x] F3 `SpendingList.vue` — `UEmpty` first-run placeholder, branched before the per-month empty
- [x] F4 `SpendingPage.vue` — `useLiveEvent("scroll_to_top")`, switcher/summary withheld on first run
- [x] T1–T6 + `Month.before?/2` unit tests
- [x] Coverage report written to `/workspace/coverage.json`

## Verification

    mix precommit    # compile --warnings-as-errors · deps.unlock · format · assets.format ·
                     # credo --strict (no issues) · sobelow (no vulns) · deps.audit ·
                     # assets.check (vue-tsc, no type errors) · test → 109 passed
    mix assets.build # client bundle + SSR bundle, both built

Plus a QuickBEAM SSR smoke render of `SpendingPage` in both states, because `assets.build` strips
types rather than checking them and SSR is where a broken prop contract actually surfaces:

- first run (`earliest: nil`) → placeholder copy present, **no** "Previous month"/"Next month"/"This month" controls
- at the floor (`earliest == value`) → header "January 2025", back arrow carries the bare
  `disabled` attribute, forward arrow does not, entry row rendered, no placeholder

## Non-vacuity of the tests (mutation checks)

| Mutation | Result |
|---|---|
| `prev:` always the previous month **and** `navigable?/2` reduced to the old future-only guard | 5 tests failed |
| `push_event("scroll_to_top", …)` removed | 1 test failed |

Both reverted; suite green afterwards.

## Review findings — disposition

| # | Agent | Severity | Finding | Disposition |
|---|---|---|---|---|
| 1 | testing-reviewer | CRITICAL | `refute_push_event` can pass spuriously (async delivery) | **Rejected.** `deps/phoenix_live_view/.../live_view_test.ex:1773` shows it is a `receive … after` with ExUnit's 100 ms `refute_receive_timeout`. The mutation run above also had it flunk with "Unexpectedly received event", proving it catches a real push. |
| 2 | testing-reviewer | CRITICAL | `month["earliest"] == nil` also passes if the key is absent | **Fixed** — `assert Map.has_key?(month, "earliest")` added first. |
| 3 | testing-reviewer | WARNING | Scroll not tested when navigating into an empty month | **Fixed** — third navigation added to the scroll test. |
| 4 | testing-reviewer | WARNING | Month-boundary flake in the forward-arrow test | **Fixed** — the clock is read once into `today`. |
| 5 | elixir-reviewer | HIGH | `navigable?/2` conflates "empty table" with "not yet loaded" | **Rejected.** `handle_event/3` only ever runs on a connected LiveView, and the connected `mount/3` runs `load_month/1` before any event can be processed, so `earliest_month` is never `nil`-because-unloaded when `select_month` arrives. A `:loading` sentinel would add a state that cannot occur. |
| 6 | elixir-reviewer | MEDIUM | `raise Ash.Error.to_error_class(error)` double-wraps | **Kept deliberately.** Idempotent, and it guarantees an exception struct rather than assuming `Ash.min/3`'s error term is already raisable. |
| 7 | elixir-reviewer | LOW | 3 queries per `load_month/1` | **Accepted.** `MIN(date)` is an index-only scan on the existing `:date` index, and the floor *must* be recomputed per load or a back-dated entry leaves a wrongly-disabled arrow (test at :196). |
| 8 | iron-law-judge | — | No violations, all 19 laws + 6 guardrails clean | Noted. |
