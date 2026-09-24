# Plan — Browse spending entries by month

**Slug:** `browse-spending-entries-by-month` · **Depth:** plan it (MEDIUM, 5/10) ·
**Stack:** Phoenix + Ash + LiveView + LiveVue + Vue + Nuxt UI

## Discovery summary

This is **not** a greenfield assignment. The previous milestone (`add-a-spending-entry`, commit
`33aa331`) already shipped the whole screen: the `SpendLog.Spending` domain, the `Entry`/`Category`
resources, `SpendLogWeb.SpendingLive`, and the `SpendingPage` Vue island with `MonthSwitcher`,
`MonthlySummary`, `SpendingList` and `AddEntryModal`. A `select_month` event and a month switcher
with a forward-arrow guard already exist.

So the `phoenix-patterns-analyst` / `hex-library-researcher` agents were **skipped deliberately** —
the conventions are already set by the code this change extends, and no new library is involved.
The two agents that had real design work were run:

| Agent | Report |
|---|---|
| `phx:ash-resource-designer` | `research/ash-resource-designer-report.md` |
| `livevue-ui-architect` (MANDATORY for UI surfaces) | `research/livevue-ui-architect-report.md` |

### What already satisfies the criteria, and what does not

| Behaviour required | State |
|---|---|
| Only the selected month's entries are shown | ✅ `read :list_for_month` + `FilterByMonth` |
| Sorted most recent at the top | ✅ `sort: [date: :desc, inserted_at: :desc]` (`entry.ex:84`) — **untested** |
| Header formatted `January 2025` | ✅ `Month.label/1` → `month.label` — **untested for a named month** |
| Forward navigation blocked at the current month | ✅ `month.next == nil` + server-side `Month.future?` guard |
| **Backward navigation blocked at the earliest entry's month** | ❌ **missing** — `month.prev` is always a string |
| **Jump to the top of the list on each navigation** | ❌ **missing** |
| **First-run placeholder + no arrows at all when nothing was ever recorded** | ❌ **missing** — today's empty state is the *per-month* one, and the arrows still render |

Three real gaps, two untested behaviours. That is the whole assignment.

## Decisions taken on top of the research

1. **`month.earliest` (nullable), not a top-level `has_entries_ever` boolean.** The UI architect
   overruled my proposed shape and is right: a boolean beside a non-null `prev` is a representable
   illegal state. One nullable field answers both questions — `nil` ⇒ nothing ever recorded ⇒ no
   arrows and the first-run prompt; non-`nil` ⇒ the back-arrow floor. Both leaf components already
   receive `month`, so no prop threading and `SpendingPage.vue`'s `defineProps` is untouched.
2. **`Ash.min(Entry, :date)`, not a `read :earliest` action.** Verified present in Ash 3.29.1.
   `{:ok, nil}` over an empty table *is* the first-run signal, so one call answers both questions.
   A sort+limit read action would return a whole record and run the full action pipeline to compute
   an aggregate. It lives in the domain module as a plain function next to `monthly_summary/2` —
   none of Ash's five reasons to prefer an action apply, and it touches exactly one domain.
   No resource change ⇒ **no `mix ash.codegen`, no migration**. The existing `index [:date]`
   already serves `MIN(date)` as an index-only scan.
3. **The server guard is `month <= earliest`, not `== earliest`.** Disabling the arrow is a UI
   affordance; a hand-crafted `select_month` payload must not be able to park the session in 1970
   (Iron Law #8). Same shape as the existing `Month.future?/2` refusal.
4. **Scroll-to-top is a server `push_event`, not a Vue watcher.** LiveView owns the month, so
   LiveView owns the "the month changed" signal. It is pushed only from the *accepted* branch of
   `select_month` — never from `submit`, which would yank the page while the user is adding
   entries. This also makes the behaviour assertable server-side with `assert_push_event/3`,
   which a `watch()` inside Vue would not be.
5. **The placeholder wording** (the criterion's `[NEEDS CLARIFICATION]`): *"No spending logged yet"*
   / *"Add your first entry and this page starts filling in, month by month."* It says **never
   recorded**, not *nothing here* — which is the single confusion this state exists to prevent,
   given the near-identical per-month empty state sitting next to it.
6. **Both empty states stay.** `earliest === null` must be tested **before** `entries.length === 0`,
   because the latter is true in both. The per-month empty state keeps its `month.label` text
   (the distinguishing signal) and keeps both arrows.

## Backend

- [ ] **B1** `lib/spend_log/spending.ex` — add `earliest_month/0`: `Ash.min(Entry, :date)` mapped to
      `Month.from_date/1`, or `nil`. Plain function, `@spec`, documented as the first-run signal.
- [ ] **B2** `lib/spend_log/spending/month.ex` — add `before?/2` (`month < other`) so the LiveView
      guard reads as a month comparison rather than a raw string compare. Keeps the "YYYY-MM sorts
      lexicographically = chronologically" trick inside the module that owns the format.

## LiveView — `lib/spend_log_web/live/spending_live.ex`

- [ ] **L1** Assign `:earliest_month` (`nil` in `mount/3`; refreshed in `load_month/1`).
- [ ] **L2** `month_prop/3` → `month_prop/4`, taking `earliest`:
      - `prev:` `nil` when `earliest == nil` or `Month.previous(month) < earliest`, else the previous month.
      - `earliest:` the earliest month string or `nil`.
- [ ] **L3** `select_month` refuses a month before `earliest` (and still refuses the future, and
      still refuses an unparseable string). Refusal = no state change, exactly as today.
- [ ] **L4** On an **accepted** month change, `push_event(socket, "scroll_to_top", %{})`.
- [ ] **L5** After a successful `submit`, the earliest month can move *backwards* (a back-dated first
      entry), so `load_month/1` must recompute it — it does, by construction, if `earliest_month/0`
      is called there.

## Frontend

### Component breakdown (all existing — no new components)

| File | Role | Change |
|---|---|---|
| `assets/vue/spending/types.ts` | contract | `Month.prev: string \| null`, add `Month.earliest: string \| null` |
| `assets/vue/spending/MonthSwitcher.vue` | leaf | disable back arrow on `prev === null`; `v-if="month.earliest !== null"` on the arrow group **and** the "This month" button; `aria-live="polite"` on the label |
| `assets/vue/spending/SpendingList.vue` | leaf | third branch, tested **first**: `earliest === null` ⇒ first-run placeholder |
| `assets/vue/SpendingPage.vue` | page | `useLiveEvent("scroll_to_top", …)` + a root `ref` to scroll to |

### Nuxt UI components (verified via the `nuxt-ui` MCP — not guessed)

- **`UEmpty`** for the first-run placeholder. `variant="naked"` (it sits inside the existing
  `UCard`; `outline` would double-border), `icon="i-lucide-wallet"`, no `actions` — a working CTA
  would mean lifting `AddEntryModal`'s open state, which is out of scope for this assignment.
- **`UButton`** (already used) — native `disabled`, which `UButton` forwards to the `<button>`, not
  `aria-disabled`.

### LiveVue integration

- **Props:** `month` gains `earliest`; `prev` becomes nullable. No new top-level prop.
- **Events:** client→server `pushEvent("select_month", {month})` (unchanged); server→client
  `useLiveEvent("scroll_to_top")` — verified against `deps/live_vue/assets/use.ts`.
- **SSR:** `useLiveEvent` registers in `onMounted`, which never runs under `renderToString`, so no
  `window` guard and no `v-ssr={false}` is needed. The scroll itself is `await nextTick()` then
  `scrollIntoView({block: "start"})` on the island root, honouring `prefers-reduced-motion`.
- **Encoder:** no new struct crosses the boundary — `earliest` is a plain string.

### Tools the work phase used

`nuxt-ui` MCP (`search-components`, `get-component-metadata`), the `nuxt-ui` and
`vue-best-practices` skills, and the LiveVue guardrails in `CLAUDE.md`.

## Tests — `test/spend_log_web/live/spending_live_test.exs`

One `describe "browsing by month"` block. Every criterion gets a test that would fail without the
change.

- [ ] **T1** (`723530cc5220`) Entries from three different months; assert the selected month's
      entries only, `month.label == "January 2025"` for a fixed month, and newest-first ordering.
- [ ] **T2** (`723530cc5220`) `assert_push_event(view, "scroll_to_top", %{})` on an accepted
      navigation, and **no** push on a refused one.
- [ ] **T3** (`6e5e8778294c`) On the current month `month.next == nil`, and a `select_month` for
      next month leaves the month unchanged.
- [ ] **T4** (`1cb6c8f0c344`) On the earliest entry's month `month.prev == nil`, and a
      `select_month` for the month before it leaves the month unchanged.
- [ ] **T5** (`098bcfa94593`) With no entries at all: `month.earliest == nil`, `month.prev == nil`,
      `month.next == nil`, `entries == []`.
- [ ] **T6** A back-dated first entry moves the floor: `earliest` follows it.
- [ ] Unit tests for `Month.before?/2` in `test/spend_log/spending/month_test.exs`.

## Verification

`mix precommit` **and** `mix assets.build` (client + SSR), per the build contract.
