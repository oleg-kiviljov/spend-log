# Code Review: Browse spending entries by month — Elixir side

## Summary
- **Status**: ⚠️ Changes Requested
- **Issues Found**: 4 (1 HIGH, 1 MEDIUM, 2 LOW)

---

## HIGH

### 1. `navigable?/2` returns `false` for any unrecorded entry — including the current month before `earliest_month` loads
**File**: `lib/spend_log_web/live/spending_live.ex:145`

```elixir
defp navigable?(_month, %{earliest_month: nil}), do: false
```

`navigable?` is only called from `handle_event("select_month", ...)`. The
connected mount sets `:earliest_month` to `nil` before `load_month/1` has run.
If a user clicks a nav arrow in the race window between the disconnected paint
and the first `load_month` completion (unlikely but possible with slow DB),
`navigable?` returns `false` and the navigation is silently dropped. More
importantly, a nil `earliest_month` can also mean "the table is genuinely
empty". These two states are treated identically but they warrant different UX.
Right now both block navigation, which is correct for the empty-table case but
incorrect during the load-in-progress window. This is not catastrophic because
the connected mount immediately calls `load_month` and pushes an update, so the
window is very short; however the silent drop of a valid event is surprising and
worth documenting at minimum. Consider using a third sentinel (e.g. `:loading`)
to distinguish "not yet fetched" from "table is empty".

---

## MEDIUM

### 2. `raise Ash.Error.to_error_class(error)` — double-wrapping is non-idiomatic
**File**: `lib/spend_log/spending.ex:74`

```elixir
{:error, error} -> raise Ash.Error.to_error_class(error)
```

`Ash.min/3` already calls `Ash.Error.to_error_class/1` internally before
returning `{:error, error}` — that is confirmed by the Ash source
(`ash.ex:1606`). Calling `to_error_class` a second time is harmless (it is
idempotent for error class structs) but misleading: it implies the value in
`error` is raw. The idiomatic pattern for re-raising an already-classified Ash
error is `raise error` (or `raise Ash.Error.to_error_class(error)` only when
the source is a raw changeset/query). Consider:

```elixir
{:error, error} -> raise error
```

If the concern is ensuring an `Ash.Error.t()` is raised, `raise error` is
sufficient because `Ash.min/3`'s contract guarantees `Ash.Error.t()` in the
error tuple. If future refactors swap `Ash.min/3` for a raw Repo call then
re-adding `to_error_class` would be appropriate.

---

## LOW

### 3. `Spending.earliest_month()` called on every `load_month/1` — three DB queries per navigation
**File**: `lib/spend_log_web/live/spending_live.ex:151–164`

```elixir
defp load_month(socket) do
  ...
  |> assign(:earliest_month, Spending.earliest_month())   # extra MIN(date) query
  ...
end
```

Every `load_month` fires three queries: `list_entries_for_month!`, `earliest_month`
(`MIN(date)` index-only scan), and `list_categories!`. The comment correctly
justifies re-fetching `earliest_month` on every load (a back-dated entry can
move the floor). The overhead is one cheap index-only scan; this is acceptable.
However it is worth noting that `list_categories!` is also re-fetched here AND
inside `handle_event("submit", …, {:error, form})` and `handle_event("open_entry_form", …)`.
No N+1 exists, but if the category list grows large the triple-fetch-per-navigation
is worth profiling. No code change required; noting for awareness.

### 4. `month_prop/3` arity mismatch with the prompt description (non-issue — confirmed correct)
The prompt said `month_prop/3` → `/4`, but the actual file shows the render
template calls `month_prop(@month, @today, @earliest_month)` (3 args) and the
private function is defined with 3 params (line 210). The signature is
internally consistent and correct. The prompt's mention of `/4` appears to be a
planning artifact — no action needed.

---

## Correctness of boundary logic (no issues found)

- **Ceiling (`today`)**: `Month.future?/2` does `month > from_date(today)` — strictly greater,
  so `current_month == today_month` is navigable (correct).
- **Floor (`earliest`)**: `Month.before?/2` does `month < earliest` — strictly less, so
  `month == earliest` is navigable (correct, no off-by-one).
- **`prev`/`next` nil-ing**: `prev` is nil-ed when `Month.before?(prev, earliest)` — i.e. the
  month before the current one is before the floor, so current is already the earliest (correct).
  `next` is nil-ed when `Month.future?(next, today)` — the month after current is in the future
  (correct).
- **Year-boundary `Date.shift`**: `shift/2` constructs `Date.new!(year, month_number, 1)` with
  day=1, then calls `Date.shift(month: offset)`. Shifting a first-of-month by ±1 months in Elixir
  always yields a valid first-of-month (no 30/31/28 day clamping concern). Verified via `Month.shift`.
- **`navigable?/2` pattern exhaustiveness**: The two clauses cover `%{earliest_month: nil}` (any
  map with that key nil) and `%{earliest_month: _, today: _}` (any map with both keys present).
  Since `socket.assigns` always has both keys after `mount/3`, no crash risk.
- **Iron Laws**: No DB in disconnected mount (✓ `connected?` guard at line 46). No
  `String.to_atom` on user input (✓). Money is `:decimal` throughout (✓). Every `handle_event`
  either validates payload shape with a guard or pattern, plus the catch-all at line 142 (✓).
