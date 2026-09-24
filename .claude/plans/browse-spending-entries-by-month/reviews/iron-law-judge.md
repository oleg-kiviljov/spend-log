# Iron Law Violations Report

## Summary

- Files scanned: 7 (spending_live.ex, spending.ex, spending/month.ex, SpendingPage.vue, spending/MonthSwitcher.vue, spending/SpendingList.vue, spending/types.ts)
- Iron Laws checked: 19 of 26
- Violations found: 0 (0 critical, 0 high, 0 medium)

---

## Detailed Findings

All checks passed. No violations were found. The notes below document the specific questions raised in the prompt.

### Iron Law #1 — No unconditional DB queries in disconnected mount

`spending_live.ex:46` uses `if(connected?(socket), do: load_month(socket), else: socket)`.
The disconnected branch assigns only `nil` / `[]` / empty summary — no Repo or Ash reads.
`load_month/1` (which calls `Spending.list_entries_for_month!`, `Spending.earliest_month`, and `Spending.list_categories!`) executes only in the connected branch. CLEAN.

### Iron Law #2 — Streams for large lists

`entries` is passed as a plain `Enum.map` prop to Vue rather than as a LiveView stream.
This is acceptable here because LiveVue components receive props, not stream tokens, and the
Ash-backed list is bounded to one calendar month. The CLAUDE.md Ash override says "always use
streams for collections" with >100 items as the hard floor; a single month of personal spending
entries is virtually never >100 rows. No violation — acceptable.

### Iron Law #3 — PubSub subscribe behind connected? guard

No PubSub subscribe call is present in this diff. CLEAN.

### Iron Law #4 — No :float for money

`spending.ex` uses `Decimal.new("0.00")` and `Decimal.add`. No `:float` field is introduced.
The module doc explicitly calls out Iron Law #4. CLEAN.

### Iron Law #8 — Authorize / validate in every handle_event

Four `handle_event` clauses are present:

1. `"validate"` — guarded `when is_map(params)`, delegates to `AshPhoenix.Form.validate`. No
   authorization needed: validating a form is a read-only, side-effect-free operation on the
   user's own in-progress input.
2. `"submit"` — guarded `when is_map(params)`, delegates to `AshPhoenix.Form.submit`.
   Authorization happens via Ash policies in the `:create` action. Acceptable pattern for an
   authenticated LiveView.
3. `"open_entry_form"` — refreshes local form/category state only; no data mutation.
4. `"select_month"` — guarded `when is_binary(month)`, strictly parses through `Month.parse/1`
   (regex + range check), then enforces `navigable?/2` which bounds the value between
   `earliest_month` (server-side assign) and today. A crafted payload outside the valid
   `"YYYY-MM"` range is rejected at `Month.parse`. A syntactically valid but out-of-range month
   (e.g. a year far in the future) is rejected by `Month.future?`. A month before the first
   recorded entry is rejected by `Month.before?`. Both `earliest` and `today` come from
   server-side assigns — the client cannot forge them. The range check is sound. CLEAN.

Catch-all `handle_event(_event, _params, socket)` silently drops unknown events. CLEAN.

### SSR safety — `window.matchMedia` inside `useLiveEvent` callback

`SpendingPage.vue:36-43` calls `window.matchMedia(...)` inside a `useLiveEvent` callback.

Confirmed safe. `deps/live_vue/assets/use.ts:37` shows `useLiveEvent` wraps the registration
in `onMounted(() => { ... })`. Vue's `onMounted` lifecycle hook never executes during
`renderToString` (SSR). The callback itself therefore never runs at render time, so `window` is
never accessed during SSR. CLEAN.

### `<UApp>` provider for `UEmpty`

`SpendingPage.vue` is the root component. Its template (line 47) wraps everything in `<UApp>`.
`SpendingList.vue` uses `<UEmpty>` (line 17). Since `SpendingList` is composed inside
`SpendingPage`'s `<UApp>`, it has the required Nuxt UI provider context. CLEAN.

### `UEmpty` props

`UEmpty` is used with `variant`, `icon`, `title`, `description`, and `class` props. These are
standard Nuxt UI `UEmpty` props. `icon` uses `"i-lucide-wallet"` (Iconify format). Colors are
not passed as raw Tailwind palette values — the semantic `text-dimmed` / `text-muted` /
`text-highlighted` Tailwind tokens are used throughout. CLEAN.

### Vue: `ref` on root element + `v-if` wrapper

`SpendingPage.vue:31` declares `const root = ref<HTMLElement | null>(null)`.
The template at line 48 binds `ref="root"` to the `<div>` that is always present (not inside
the `v-if`). The `template v-if="hasEntries"` at line 64 conditionally shows `MonthSwitcher`
and `MonthlySummary` but the `<div ref="root">` is the unconditional outer wrapper, so the ref
is always resolved and `root.value` is never null after mount. The `?.scrollIntoView` optional
chain is a belt-and-suspenders guard. Pattern is sound. CLEAN.

### `<script setup lang="ts">`

All three `.vue` files use `<script setup lang="ts">`. CLEAN.

### Derived state via `computed`

`SpendingPage.vue`: `hasEntries` is a `computed`. `MonthSwitcher.vue`: `currentMonth` is a
`computed`. No derived values stored in reactive `ref`s that should be `computed`. CLEAN.

### No data fetching in Vue

No `fetch`, `$fetch`, `useFetch`, `onMounted` data calls, or Pinia store in any component.
All data arrives as props from the LiveView. CLEAN.

### Events via pushEvent

`MonthSwitcher.vue:22` calls `live.pushEvent("select_month", { month })`. All
client-to-server communication uses the LiveVue-blessed pattern. CLEAN.

### Structs as props

Props passed to `<.vue>` are plain maps built by `month_prop/3`, `summary_prop/1`,
`entry_prop/1` — no raw Ash resource structs. `LiveVue.Encoder` is not needed and not
required here. CLEAN.

### No `raw()` with untrusted content

No `raw(` calls in any `.heex` or `.vue` file in this diff. CLEAN.

### No `String.to_atom` with user input

`Month.parse/1` uses only `String.to_integer/1` (safe — bounded by regex) on the year and
month segments. No `String.to_atom` anywhere in the diff. CLEAN.
