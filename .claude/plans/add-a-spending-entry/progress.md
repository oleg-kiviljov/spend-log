# Progress — Add a spending entry

**State:** COMPLETED · **Cycles:** 1 (plan → work → verify → review → fix → re-verify)

## Phases

| Phase | Outcome |
|---|---|
| DISCOVERING | Fresh scaffold, no Ash domains. Complexity 8/10 → deep planning. Headless, so the depth choice was made here rather than asked. |
| PLANNING | 2 research agents run (`ash-resource-designer`, `livevue-ui-architect` — the latter mandatory for UI surfaces). `phoenix-patterns-analyst` and library research **skipped**: no existing domain code to analyse, no library decision to make. Plan at `plan.md`. |
| WORKING | Backend (domain, 2 resources, 2 validations, 1 preparation, 2 support modules, migration, seeds) + frontend (LiveView + 5 `.vue` files + shared types) + tests. |
| VERIFYING | `mix precommit` and `mix assets.build` (client **and** SSR) green. Dev server booted and `/` fetched: island renders, no errors. |
| REVIEWING | 4 specialists in parallel. |
| FIX | 1 real crash fixed, 3 test-honesty defects fixed, 1 index added. Re-verified. |

## Review findings and what was done

| Finding | Source | Severity | Action |
|---|---|---|---|
| Non-map `"form"` payload crashes the LiveView (`BadMapError` in `AshPhoenix.Form.validate/3`) | security-analyzer | MEDIUM | **Fixed** — reproduced the crash first, then added `is_map`/`is_binary` guards and a catch-all `handle_event/3`. Regression tests at `spending_live_test.exs:86-110`. |
| `assert_reply` might be a false positive | testing-reviewer | CRITICAL (claimed) | **Disproved** — mutated the handler to `{:noreply, …}`; exactly that one test failed. The assertion is genuine. No change. |
| `assert ~w(...) = ...` (match, not equality) in the two alphabetical-order tests | testing-reviewer | WARNING | **Fixed** — changed to `==` in both files. |
| `future?/2` test used `~D[2026-09-21]`, so it could not catch an implementation that ignored the argument and read the clock | testing-reviewer | WARNING | **Fixed** — anchored on `~D[2020-05-15]`, which now discriminates. |
| Missing LiveView-layer boundary tests (exactly €1.00 / €1,000,000.00, today accepted) | testing-reviewer | SUGGESTION | **Fixed** — added. |
| No index on `spending_entries.date` | security-analyzer | LOW | **Fixed** — `custom_indexes` + generated migration. |
| Entries as a plain list prop, not a stream (Iron Law #2 / Ash override) | iron-law-judge | HIGH (claimed) | **Not changed — deliberate.** A LiveVue island receives its whole collection as an encoded prop, so a stream would not reduce what crosses the wire, and the suggested mitigation (cap the query at N) would silently hide a user's own entries — a worse failure than the memory it saves. A personal month of spending is far under the >100 floor. Documented here rather than silently ignored; revisit if the product ever gains multi-user or multi-year lists. |
| `select_month` discards the parsed tuple and stores the raw string | iron-law-judge | SUGGESTION | **Not changed** — `Month.parse/1` is anchored (`^\d{4}-\d{2}$` plus range checks), so the stored string is already canonical by construction. |
| `Month.previous("0001-01")` yields `"0000-12"`, which `parse/1` then rejects | security-analyzer | INFO | **Not changed** — unreachable from the UI (paging starts at today and the control is bounded). |
| Unbounded `note` retained in assigns before `max_length: 500` rejects it | security-analyzer | LOW | **Not changed** — needs an endpoint `max_frame_size`, which is app-wide configuration outside this assignment. |

**`elixir-reviewer` produced no report.** It ran, traced `Decimal.add/2` argument order (commutative — fine) and `AshPhoenix.Form.errors(for_path: :all)` (confirmed `{field, message}` tuples with `nil` field for form-level errors, so `form_level_error/1` works), but its output was truncated and it never wrote `reviews/elixir-reviewer.md`. The other three reviews plus `credo --strict` covered the same ground; noting the gap rather than claiming four reviews landed.

## Final gate

```
mix precommit   → 95 passed (5 doctests, 90 tests); credo --strict, sobelow, deps.audit, typecheck all clean
mix assets.build → client + SSR bundles both built
mix phx.server   → / returns 200, island renders, 0 errors
```

## Out of scope (see plan.md)

Editing/deleting entries, soft delete + recovery (TRM-007/INV-024), the category filter (TRM-008),
category management UI, *Uncategorized* reassignment on category delete (TRM-005).
