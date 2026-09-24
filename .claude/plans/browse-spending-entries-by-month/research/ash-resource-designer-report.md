# Ash Resource Designer Report — Earliest Recorded Month

Assignment: Browse spending entries by month
Capability needed: Know the month containing the earliest recorded Spending Entry, and whether any
entry has ever been recorded at all.

---

## 1. Read action vs aggregate vs `Ash.Query` — which is correct?

### Ash.min/3 is the right call

`Ash.min(query, field, opts)` → `{:ok, %Date{} | nil} | {:error, Ash.Error.t()}`

Verified in `deps/ash/lib/ash.ex` lines 1592–1608 (Ash 3.29.1):

```elixir
def min(query, field, opts \\ []) do
  {aggregate_opts, opts} = Ash.Query.Aggregate.split_aggregate_opts(opts)
  case aggregate(query, {:min, :min, Keyword.put(aggregate_opts, :field, field)}, opts) do
    {:ok, %{min: value}} -> {:ok, value}
    {:error, error}      -> {:error, Ash.Error.to_error_class(error)}
  end
end
```

- When there are no rows, `Ash.min` returns `{:ok, nil}` (SQL MIN over an empty set is NULL).
- A `nil` result answers both questions at once: `nil` means no entries exist; a `%Date{}` means at
  least one does. **One call answers both questions — no separate `Ash.exists?` needed.**

### Why NOT a read action with sort+limit

A `read :earliest` with `prepare build(sort: [date: :asc], limit: 1)` works, but is heavier:
- It returns a full record with all attributes; we only need one field.
- It pulls data through the full action pipeline (changes, loads, serialisation).
- It requires a new code interface `define` and a named action for a lookup that is really an
  aggregation, not a record read.
- Ash's five reasons to prefer an action over a plain function: API extension, cast inputs,
  policies, code interface, `transaction? true`. None apply here — the aggregation needs none of
  those.

### Why NOT a resource-level `aggregates do` block

Resource-level aggregates (`:min`, `:max`, `:count` …) are defined as **relationships** from one
resource into another or as a relationship rollup. A standalone MIN over the same resource is not
a relationship aggregate — it is a whole-table aggregation. The right tool is the standalone
`Ash.min/3` function.

---

## 2. Exact code

### No new action on Entry required

`Ash.min` operates on any query for a resource in the domain. The default `:read` action already
exists (`defaults [:read]` in `entry.ex`). No additional action definition is needed.

### New plain function in `SpendLog.Spending`

```elixir
@doc """
The month string `"YYYY-MM"` containing the earliest recorded entry, or `nil` when no
entries have ever been recorded.

A `nil` result is also the canonical signal that the app is in first-run state (no entries).
A non-nil result proves at least one entry exists — no separate existence check is required.

A plain function rather than a generic action: none of Ash's five reasons to prefer an action
apply (no API extension, no cast inputs, no policies, no transaction). The computation is a
whole-table MIN aggregate, not a record read, so a resource-level `aggregates do` block does
not apply either.
"""
@spec earliest_month() :: SpendLog.Spending.Month.t() | nil
def earliest_month do
  case Ash.min(SpendLog.Spending.Entry, :date, authorize?: false) do
    {:ok, nil}        -> nil
    {:ok, %Date{} = d} -> SpendLog.Spending.Month.from_date(d)
    {:error, error}   -> raise Ash.Error.to_error_class(error)
  end
end
```

### Why `authorize?: false`

`SpendLog.Spending.Entry` has no `authorizers: [Ash.Policy.Authorizer]` (confirmed: no
`authorizers`/`Ash.Policy` references anywhere in `lib/spend_log`). Without an authorizer,
`authorize?: false` is redundant but explicit — it documents intent and keeps the call safe if an
authorizer is added later. The domain's existing `monthly_summary/2` already calls
`list_entries_for_month!/1` with no actor, setting the same precedent. If the resource gains
policies, `authorize?: false` here would then need justification (system-internal read with no
actor context).

### Code interface: NOT needed

The code interface layer (`define` blocks in `SpendLog.Spending`) is for **actions**. This is a
plain function, not an action. It lives directly in the domain module as a public function with a
spec. The same pattern is already used for `monthly_summary/2` and `summarize/1`.

### Returned shape

`String.t() | nil` — a `"YYYY-MM"` string, or `nil`. Consumers:

```elixir
case SpendLog.Spending.earliest_month() do
  nil    -> # first-run: show placeholder
  month  -> # disable back arrow when current_month == month
end
```

---

## 3. Placement: resource, domain module, or `SpendLog.Spending.Month`?

**Goes in `SpendLog.Spending` (the domain module) as a plain function.**

Placement rule: count alias/call references to Ash.Domain namespaces.
- Touches only `SpendLog.Spending` domain resources (specifically `Entry`).
- Produces a `SpendLog.Spending.Month.t()` value.
- 1 domain → belongs in that domain's folder/module.

`SpendLog.Spending.Month` is a pure value-type module (string formatting, parsing, shifting,
`future?/2`). It has no knowledge of persistence or the `Entry` resource — adding a DB-touching
function there would violate its pure-value contract and make it import/call into its sibling domain
layer.

Ash's five reasons to prefer an action over a plain function (from `code_structure.md`):
1. API extension (JSON:API, GraphQL) — not needed, internal use only.
2. Cast inputs — no inputs.
3. Policies — no authorizer on Entry.
4. Code interface — not relevant for a plain function.
5. `transaction? true` — no writes.

None apply. Plain function is correct.

---

## 4. Index / performance

`entry.ex` already declares:

```elixir
custom_indexes do
  index [:date]
end
```

A B-tree index on `date` directly supports `MIN(date)` — PostgreSQL will satisfy the aggregation
with an Index Only Scan on the leftmost value, typically a single 8-byte read regardless of table
size. No additional index is needed.

---

## 5. Ash gotchas

### `authorize?:` and `actor:`

- The resource has no authorizer, so authorization is moot today.
- Pass `authorize?: false` to be explicit and forward-safe (matching the existing `monthly_summary`
  precedent of calling without an actor).
- Never pass `actor: current_user` at the *execution* call site for an aggregate (this app does
  not appear to use `Ash.Scope`).

### `Ash.min` vs `Ash.read_one` / `Ash.read_first`

- `Ash.min` → `{:ok, value_or_nil}` — exact fit.
- `Ash.read_one` → `{:ok, record_or_nil} | {:error, ...}` — would work with a sorted+limited
  query, but returns a full record, and can raise if more than one record matches (without
  `allow_nil?: true` / unique filter).
- `Ash.read_first` → `{:ok, record_or_nil}` — works, but same overhead as `read_one`.

`Ash.min` is the lowest-overhead, most semantically precise option.

### Empty-set nil handling

SQL `MIN()` over zero rows returns `NULL`; Ash surfaces this as `{:ok, nil}`. The function can
distinguish nil-no-entries from nil-error by always wrapping the error branch in a `raise`.

### Bang variant

A `earliest_month!` variant is not appropriate here. The function returns `nil` for "no entries"
(a normal, expected, non-error state). Raising on `nil` would conflate "no data" with "error".
The `!` convention in Ash (and this project) means "raise on `{:error, _}`" — not "raise on `nil`".
The implementation already raises on `{:error, _}` and returns `nil` cleanly.

---

## Recommended code to add to `lib/spend_log/spending.ex`

Add after `summarize/1`, before `defp sum_amounts`:

```elixir
@doc """
The month string `"YYYY-MM"` containing the earliest recorded entry, or `nil` when no
entries have ever been recorded.

`nil` is the canonical first-run signal — no separate existence check is required.

A plain function rather than a generic action: no API extension, no cast inputs, no policies,
no transaction needed.
"""
@spec earliest_month() :: SpendLog.Spending.Month.t() | nil
def earliest_month do
  case Ash.min(SpendLog.Spending.Entry, :date, authorize?: false) do
    {:ok, nil}         -> nil
    {:ok, %Date{} = d} -> SpendLog.Spending.Month.from_date(d)
    {:error, error}    -> raise Ash.Error.to_error_class(error)
  end
end
```

No resource changes. No migration. No `mix ash.codegen` needed.
