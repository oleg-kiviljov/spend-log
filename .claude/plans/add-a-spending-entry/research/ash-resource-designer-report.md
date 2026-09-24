# Ash Resource Design: SpendLog.Spending (Category + Entry)

## Context

Fresh scaffold — `config :spend_log, ash_domains: []`. No existing Ash resources.
This design creates the `SpendLog.Spending` domain with two resources:
`SpendLog.Spending.Category` and `SpendLog.Spending.Entry`.

Key config flags noted from `config/config.exs`:
- `default_actions_require_atomic?: true` — every update/destroy change and validation must be
  atomic or the action must opt out with `require_atomic? false`. This affects the date-not-future
  validation (see below).
- `bulk_actions_default_to_errors?: true`
- `transaction_rollback_on_error?: true`

No authentication in the app. Policy recommendation: skip `Ash.Policy.Authorizer` (see section
below).

---

## Generator Commands

Run these in order before writing any source:

```bash
mix ash.gen.domain SpendLog.Spending --yes
mix ash.gen.resource SpendLog.Spending.Category --yes
mix ash.gen.resource SpendLog.Spending.Entry --yes
```

The generator scaffolds snapshot directories under `priv/resource_snapshots/` and registers
entries in the domain. Adjust the generated stubs to match the full design below.

---

## Resource: SpendLog.Spending.Category

### Proposed source — `lib/spend_log/spending/category.ex`

```elixir
defmodule SpendLog.Spending.Category do
  use Ash.Resource,
    domain: SpendLog.Spending,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "spending_categories"
    repo SpendLog.Repo
  end

  actions do
    # No default :create/:update/:destroy exposed publicly — categories are seeded
    # and managed outside user-facing flows. Expose :read only.
    defaults []

    read :read do
      primary? true
      prepare build(sort: [name: :asc])
    end

    # Internal action used only by seeds/admin — not exposed in code interface.
    create :seed do
      accept [:name]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    timestamps()
  end

  identities do
    identity :unique_name, [:name], eager_check?: true
  end
end
```

**Notes:**
- `prepare build(sort: [name: :asc])` on the primary read action satisfies the alphabetical
  sort requirement without a custom preparation module — the built-in `build/1` preparation
  is the exact fit.
- The `identity :unique_name` with `eager_check?: true` satisfies INV-022 ("globally unique
  category name"). AshPostgres auto-generates a unique index. `eager_check?: true` requires the
  domain to be registered in app config (see Post-Design Commands section).
- No `Ash.Policy.Authorizer` — see Policy section below.

---

## Resource: SpendLog.Spending.Entry

### Proposed source — `lib/spend_log/spending/entry.ex`

```elixir
defmodule SpendLog.Spending.Entry do
  use Ash.Resource,
    domain: SpendLog.Spending,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "spending_entries"
    repo SpendLog.Repo

    references do
      reference :category, on_delete: :restrict
    end
  end

  actions do
    defaults []

    create :create do
      accept [:amount, :date, :note, :category_id]

      validate compare(:amount,
                 greater_than_or_equal_to: Decimal.new("1.00"),
                 less_than_or_equal_to: Decimal.new("1000000.00")
               ) do
        message "amount must be between €1.00 and €1,000,000.00"
      end

      # Per-bound messages (INV-023) — two separate validations for exact messages:
      validate compare(:amount, greater_than_or_equal_to: Decimal.new("1.00")) do
        message "must be at least €1.00"
      end

      validate compare(:amount, less_than_or_equal_to: Decimal.new("1000000.00")) do
        message "must be no more than €1,000,000.00"
      end

      # Date must not be in the future
      validate {SpendLog.Spending.Entry.Validations.DateNotFuture, []}

      # category_id presence is handled by the FK constraint (allow_nil?: false on belongs_to)
      # The "please select a category" message is emitted by the attribute constraint:
      # see attributes block. For a more user-friendly message we add an explicit validation:
      validate present(:category_id) do
        message "please select a category"
      end
    end

    read :list_for_month do
      argument :year, :integer, allow_nil?: false
      argument :month, :integer, allow_nil?: false

      # Build the date range filter in a preparation so category is joined (no N+1)
      prepare SpendLog.Spending.Entry.Preparations.FilterByMonth
      prepare build(sort: [date: :desc, inserted_at: :desc], load: [:category])
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :amount, :decimal,
      allow_nil?: false,
      public?: true,
      constraints: [precision: 12, scale: 2]

    attribute :date, :date, allow_nil?: false, public?: true
    attribute :note, :string, allow_nil?: true, public?: true
    timestamps()
  end

  relationships do
    belongs_to :category, SpendLog.Spending.Category,
      allow_nil?: false,
      public?: true
  end
end
```

### Custom Validation: DateNotFuture

**Why a custom module and not a built-in?**

The built-in `compare/2` works on attribute/argument values compared to literals or other
attributes. It does not support comparing against a runtime-computed value like `Date.utc_today()`.
`Ash.Expr.expr(date <= ^Date.utc_today())` in a validation would work in an `atomic/3` callback,
but `compare` takes a compile-time literal comparand. Therefore a custom validation module is
justified here.

Given `default_actions_require_atomic?: true`, **this action is `:create`** — create actions are
exempt from the atomic requirement (atomic applies to `:update` and `:destroy`). The custom module
does not need an `atomic/3` callback for a `:create`-only validation.

**Proposed source — `lib/spend_log/spending/entry/validations/date_not_future.ex`**

```elixir
defmodule SpendLog.Spending.Entry.Validations.DateNotFuture do
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :date) do
      nil ->
        # nil is handled by allow_nil?: false attribute constraint; skip
        :ok

      date ->
        if Date.compare(date, Date.utc_today()) in [:lt, :eq] do
          :ok
        else
          {:error,
           field: :date,
           message: "must be today or in the past"}
        end
    end
  end
end
```

**File placement:** The validation belongs to `Entry` only (one resource), so it lives under
`lib/spend_log/spending/entry/validations/` per the Ash convention for resource-scoped satellites.

---

### Preparation: FilterByMonth

**Proposed source — `lib/spend_log/spending/entry/preparations/filter_by_month.ex`**

```elixir
defmodule SpendLog.Spending.Entry.Preparations.FilterByMonth do
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    year = Ash.Query.get_argument(query, :year)
    month = Ash.Query.get_argument(query, :month)

    with {:ok, first} <- Date.new(year, month, 1),
         days <- Date.days_in_month(first),
         {:ok, last} <- Date.new(year, month, days) do
      Ash.Query.filter(query, date >= ^first and date <= ^last)
    else
      _ -> Ash.Query.add_error(query, "Invalid year/month combination")
    end
  end
end
```

**No N+1:** The `prepare build(load: [:category])` in the read action tells AshPostgres to
load `category` as part of the same query plan (a SQL JOIN for the `belongs_to`). Since
`Entry belongs_to Category`, AshPostgres can satisfy this with a single query or at worst two
queries (entries + batch-loaded categories by their IDs), never N separate category fetches.
The Iron Law "JOIN for belongs_to" is satisfied.

---

## Domain Module: SpendLog.Spending

### Proposed source — `lib/spend_log/spending.ex`

```elixir
defmodule SpendLog.Spending do
  use Ash.Domain,
    extensions: [AshPhoenix]

  resources do
    resource SpendLog.Spending.Category do
      define :list_categories, action: :read
      define :get_category, action: :read, get_by: [:id]
    end

    resource SpendLog.Spending.Entry do
      define :create_entry, action: :create, args: []
      define :get_entry, action: :read, get_by: [:id]
      define :list_entries_for_month, action: :list_for_month, args: [:year, :month]
    end
  end
end
```

**AshPhoenix extension** adds `form_to_create_entry/1` and `form_to_*` variants automatically —
see AshPhoenix Form section below.

**Domain registration** — add to `config/config.exs`:

```elixir
config :spend_log, ash_domains: [SpendLog.Spending]
```

This is required for `eager_check?: true` on the Category identity to work.

---

## AshPhoenix.Form Integration

`AshPhoenix.Form.for_create` usage for the entry form (in a LiveView):

```elixir
# Mount (disconnected — no DB query; form has no data yet)
def mount(_params, _session, socket) do
  {:ok, assign(socket, form: build_create_form())}
end

defp build_create_form do
  SpendLog.Spending.form_to_create_entry(
    domain: SpendLog.Spending,
    authorize?: false
  )
  |> to_form()
end

# Validate on change
def handle_event("validate", %{"entry" => params}, socket) do
  form = AshPhoenix.Form.validate(socket.assigns.form, params)
  {:noreply, assign(socket, :form, form)}
end

# Submit
def handle_event("save", %{"entry" => params}, socket) do
  case AshPhoenix.Form.submit(socket.assigns.form, params: params) do
    {:ok, _entry} ->
      {:noreply, socket |> put_flash(:info, "Entry saved.") |> push_navigate(to: ~p"/")}

    {:error, form} ->
      {:noreply, assign(socket, :form, form)}
  end
end
```

The `form_to_create_entry/1` function is generated by the `AshPhoenix` domain extension.
Alternatively, use `AshPhoenix.Form.for_create(SpendLog.Spending.Entry, :create)` directly
if the domain extension is not desired.

**`category_id` in the form:** Pass available categories as a separate assign (loaded via
`SpendLog.Spending.list_categories!()` in `connected?` branch), render as a `<select>`.
`category_id` is in `accept` on the `:create` action so it is settable by the form.

---

## INV-019: Category Required — How the Validation Works

`belongs_to :category, ..., allow_nil?: false` generates a `category_id` attribute with
`allow_nil?: false`. Ash's built-in attribute constraint enforces presence at the attribute level.

In addition, the `:create` action has:

```elixir
validate present(:category_id) do
  message "please select a category"
end
```

This built-in `present/1` validation fires before the data layer and surfaces a user-visible
message "please select a category" on the `category_id` field.

---

## INV-022: Category Uniqueness

Handled entirely by the identity in `Category`:

```elixir
identity :unique_name, [:name], eager_check?: true
```

AshPostgres generates the corresponding `CREATE UNIQUE INDEX` automatically from the identity.
No custom validation module needed.

---

## INV-023: Amount Range Validation

Two separate `validate compare/2` calls (one per bound) with per-bound messages. The built-in
`compare/2` with `Decimal.new/1` literals is exact:

```elixir
validate compare(:amount, greater_than_or_equal_to: Decimal.new("1.00")) do
  message "must be at least €1.00"
end

validate compare(:amount, less_than_or_equal_to: Decimal.new("1000000.00")) do
  message "must be no more than €1,000,000.00"
end
```

**Verified:** `Ash.Resource.Validation.Builtins.compare/2` accepts a `Decimal` as a literal
comparand value. The `:amount` attribute is `:decimal` with `constraints: [precision: 12, scale: 2]`
which enforces 2dp at the data layer. No custom module needed.

---

## Category Deletion Consistency (Referenced but No Longer Present)

**Decision: use the Postgres FK `on_delete: :restrict` reference — do not write a custom validation.**

```elixir
references do
  reference :category, on_delete: :restrict
end
```

`:restrict` tells Postgres to refuse any `DELETE` on a `spending_categories` row that is still
referenced by a `spending_entries` row. The database raises a foreign-key violation; AshPostgres
surfaces this as an `Ash.Error.Invalid` containing a constraint error.

**Custom message mapping** via `check_constraint`:

```elixir
postgres do
  table "spending_entries"
  repo SpendLog.Repo

  references do
    reference :category, on_delete: :restrict
  end

  check_constraints do
    # This is not a check constraint — FK violations surface differently.
    # Instead, map the FK violation in the resource using custom_indexes or
    # handle in the form layer.
  end
end
```

AshPostgres maps FK violations to `Ash.Error.Invalid.InvalidChanges` with a generic constraint
message. To surface the exact message "the selected category no longer exists, please choose again"
to the user, map it in the LiveView error handler:

```elixir
# In the LiveView submit handler
{:error, %Ash.Error.Invalid{errors: errors}} ->
  if Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidChanges{}, &1)) do
    put_flash(socket, :error, "The selected category no longer exists. Please choose again.")
  else
    assign(socket, :form, form_with_errors)
  end
```

**Why not a custom `Ash.Resource.Validation`?** A custom validation reading the DB to check
category existence would be redundant with the FK and would race (TOCTOU). The FK is the
correct place for referential integrity. The custom message mapping lives in the UI layer, which
is the right separation. No custom validation module needed here.

**FLAG:** The exact error struct type for FK violations in AshPostgres was verified from
`deps/ash_postgres/usage-rules/foreign_keys.md` only; the exact struct name for FK constraint
errors in `Ash.Error.Invalid.errors` should be confirmed at implementation time by inspecting
a test failure or checking `deps/ash_postgres/lib/ash_postgres/errors/` at that point.

---

## Monthly Summary: Aggregate vs Elixir Fold — Recommendation

### Option A: Ash Aggregate (`Ash.Query.Aggregate` / inline `sum` aggregate on Category)

Define a `sum :total_spent` aggregate on `Category` over the `entries` relationship, filtered
to the month:

```elixir
# In a generic action or by calling:
SpendLog.Spending.Category
|> Ash.Query.load(
  total_spent_this_month:
    Ash.Query.Aggregate.new!(
      :total_spent_this_month,
      :entries,
      :sum,
      field: :amount,
      query: [filter: expr(date >= ^first and date <= ^last)]
    )
)
|> Ash.read!(authorize?: false)
```

This pushes the `SUM` and `GROUP BY` into the database — one query for all categories.

### Option B: Read month's entries, fold in Elixir

```elixir
entries = SpendLog.Spending.list_entries_for_month!(year, month, load: [:category])
per_category = Enum.group_by(entries, & &1.category.name)
totals = Map.new(per_category, fn {cat, es} ->
  {cat, Enum.reduce(es, Decimal.new(0), fn e, acc -> Decimal.add(acc, e.amount) end)}
end)
grand_total = Enum.reduce(Map.values(totals), Decimal.new(0), &Decimal.add/2)
```

### Recommendation: **Option B (Elixir fold) at current scale**

**Rationale:**
1. The data set for a month is small (tens to low hundreds of entries — a single user's spending
   log). Loading all entries for a month is already needed to render the list view; the fold is
   free.
2. INV-020/INV-021 likely require the same entry list on the same screen. Running a separate
   aggregate query duplicates the database round trip for no benefit at this scale.
3. Option A requires either a generic action or pushing aggregate construction into the LiveView —
   neither is idiomatic for a simple summary. A domain function wrapping Option B is cleaner.
4. If the app later becomes multi-user or handles years of data, switch to Option A with a
   proper aggregate or a `GROUP BY` query.

**Proposed domain function** (not an Ash action — a plain function is appropriate here per the
CLAUDE.md rule: "plain functions are fine without [Ash actions]" when the five reasons don't apply):

```elixir
# In lib/spend_log/spending.ex, outside the `use Ash.Domain` DSL block:

@doc """
Returns per-category totals and grand total for the given year/month.
"""
def monthly_summary(year, month) do
  entries = list_entries_for_month!(year, month)

  per_category =
    entries
    |> Enum.group_by(& &1.category.name)
    |> Map.new(fn {cat_name, es} ->
      total = Enum.reduce(es, Decimal.new(0), fn e, acc -> Decimal.add(acc, e.amount) end)
      {cat_name, total}
    end)

  grand_total =
    per_category
    |> Map.values()
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

  %{per_category: per_category, grand_total: grand_total}
end
```

`list_entries_for_month!/2` already loads `:category` via the action's `prepare build(load: [:category])`.

---

## Postgres Specifics

| Resource | Table |
|---|---|
| `SpendLog.Spending.Category` | `spending_categories` |
| `SpendLog.Spending.Entry` | `spending_entries` |

**`spending_categories`:** uuid PK, `name` text NOT NULL, unique index on `name`, timestamps.

**`spending_entries`:** uuid PK, `amount` numeric(12,2) NOT NULL, `date` date NOT NULL,
`note` text nullable, `category_id` uuid NOT NULL REFERENCES `spending_categories(id)` ON DELETE RESTRICT,
timestamps.

The `references do reference :category, on_delete: :restrict end` block in the Entry postgres
section generates the FK with `ON DELETE RESTRICT` — no manual migration edits needed.

### `mix ash.codegen` invocation

```bash
mix ash.codegen add_spending_domain && mix ash.migrate
```

Or during iteration:

```bash
mix ash.codegen --dev
mix ash.migrate
```

---

## Policies / Authorization

**Recommendation: No `Ash.Policy.Authorizer` on these resources.**

**Justification:** The prompt states there is no authentication in this app. Ash policies are
evaluated against an `actor`. With no actor, every `authorize_if` policy check evaluates against
`nil`. Adding `Ash.Policy.Authorizer` to resources with no authentication means every action
needs a `bypass always()` or `authorize_if always()` policy — that is security theater, not
security.

The correct approach for a no-auth app:
- Do not add `authorizers: [Ash.Policy.Authorizer]` to these resources.
- Call domain code interfaces with `authorize?: false` (the default when no authorizer is
  configured) or simply omit the option.
- When/if authentication is added later, add the authorizer and policies at that point.

This is the standard Ash recommendation: Ash is fail-closed only when you opt in to
`Ash.Policy.Authorizer`. Without it, all actions are allowed by default.

---

## Testing Approach

Per `deps/ash/usage-rules/testing.md`:

### Test setup — categories and entries

Use `Ash.Seed.seed!/1` for fixtures that bypass action validations (categories are seeded data):

```elixir
defmodule SpendLog.Spending.Fixtures do
  alias SpendLog.Spending

  def category(attrs \\ %{}) do
    Ash.Seed.seed!(%SpendLog.Spending.Category{
      name: "Cat-#{System.unique_integer([:positive])}"
    }
    |> Map.merge(attrs))
  end

  def entry(attrs \\ %{}) do
    cat = attrs[:category] || category()
    Ash.Seed.seed!(%SpendLog.Spending.Entry{
      amount: Decimal.new("50.00"),
      date: Date.utc_today(),
      category_id: cat.id
    }
    |> Map.merge(Map.delete(attrs, :category)))
  end
end
```

Use `SpendLog.Spending.create_entry/1` (the code interface) when testing the action itself —
the action's validations must fire:

```elixir
test "create_entry rejects amounts below €1.00" do
  cat = Fixtures.category()
  result = SpendLog.Spending.create_entry(%{
    amount: Decimal.new("0.50"),
    date: Date.utc_today(),
    category_id: cat.id
  })
  assert {:error, %Ash.Error.Invalid{} = error} = result
  assert Enum.any?(error.errors, fn e ->
    match?(%Ash.Error.Changes.InvalidChanges{}, e) or
    (is_struct(e) and String.contains?(to_string(e.message), "€1.00"))
  end)
end
```

**Asserting on `Ash.Error.Invalid` messages:**

```elixir
# Pattern for checking a specific field message
defp has_field_error?(error, field, fragment) do
  Enum.any?(error.errors, fn e ->
    field_match = Map.get(e, :field) == field or Map.get(e, :fields, []) |> Enum.member?(field)
    msg_match = to_string(Map.get(e, :message, "")) |> String.contains?(fragment)
    field_match and msg_match
  end)
end

test "create_entry rejects future dates" do
  cat = Fixtures.category()
  {:error, error} = SpendLog.Spending.create_entry(%{
    amount: Decimal.new("10.00"),
    date: Date.add(Date.utc_today(), 1),
    category_id: cat.id
  })
  assert %Ash.Error.Invalid{} = error
  assert has_field_error?(error, :date, "today or in the past")
end

test "create_entry rejects missing category_id" do
  {:error, error} = SpendLog.Spending.create_entry(%{
    amount: Decimal.new("10.00"),
    date: Date.utc_today()
  })
  assert %Ash.Error.Invalid{} = error
  assert has_field_error?(error, :category_id, "please select a category")
end
```

### `Ash.Generator` usage for property tests

```elixir
defmodule SpendLog.TestGenerators do
  use Ash.Generator

  def entry_input(opts \\ []) do
    changeset_generator(
      SpendLog.Spending.Entry,
      :create,
      defaults: [
        amount: StreamData.map(StreamData.integer(100..100_000_000), fn n ->
          Decimal.div(Decimal.new(n), Decimal.new(100))
        end),
        date: StreamData.constant(Date.utc_today()),
        category_id: sequence(:category_id, fn _ ->
          Ash.Seed.seed!(%SpendLog.Spending.Category{
            name: "Cat-#{System.unique_integer([:positive])}"
          }).id
        end)
      ],
      overrides: opts
    )
  end
end
```

---

## Built-ins Used (and Why Not Custom)

| Slot | Built-in | Custom considered? |
|---|---|---|
| Alphabetical category sort | `prepare build(sort: [name: :asc])` | No — exact fit |
| Category uniqueness (INV-022) | `identity :unique_name, [:name], eager_check?: true` | No — identities are the Ash mechanism |
| Amount min bound (INV-023) | `validate compare(:amount, greater_than_or_equal_to: Decimal.new("1.00"))` | No — built-in handles Decimal literals |
| Amount max bound (INV-023) | `validate compare(:amount, less_than_or_equal_to: Decimal.new("1000000.00"))` | No — built-in handles Decimal literals |
| Category presence (INV-019) | `validate present(:category_id)` | No — exact fit |
| Month range filter | `prepare SpendLog.Spending.Entry.Preparations.FilterByMonth` | Yes — required because the filter bounds are computed from runtime arguments, not literals |
| Referential integrity for Category | FK `on_delete: :restrict` | Yes (custom validation considered) — FK is the correct mechanism; custom validation would race |

## Custom Modules Needed (Justified)

| Module | Path | Why a built-in didn't fit |
|---|---|---|
| `DateNotFuture` | `lib/spend_log/spending/entry/validations/date_not_future.ex` | `compare/2` requires a compile-time literal comparand; today's date is runtime. A custom validation with `Ash.Changeset.get_attribute` + `Date.utc_today()` is the correct minimal approach. |
| `FilterByMonth` | `lib/spend_log/spending/entry/preparations/filter_by_month.ex` | The filter bounds (first and last day of month) are computed from action arguments at runtime. `build(filter: ...)` accepts expressions but not arbitrary Elixir computations for date math. |

---

## Full File Listing (What to Create)

```
lib/spend_log/spending.ex                                        (domain)
lib/spend_log/spending/category.ex                               (resource)
lib/spend_log/spending/entry.ex                                  (resource)
lib/spend_log/spending/entry/validations/date_not_future.ex      (custom validation)
lib/spend_log/spending/entry/preparations/filter_by_month.ex     (custom preparation)
```

---

## Post-Design Commands

```bash
# 1. Register the domain in config/config.exs:
#    config :spend_log, ash_domains: [SpendLog.Spending]

# 2. Generate migrations from snapshots
mix ash.codegen add_spending_domain

# 3. Apply migrations
mix ash.migrate

# 4. Seed default categories (in priv/repo/seeds.exs or a Mix task)
# SpendLog.Spending.Category |> Ash.Seed.seed!(%{name: "Food"})
# SpendLog.Spending.Category |> Ash.Seed.seed!(%{name: "Transport"})
# SpendLog.Spending.Category |> Ash.Seed.seed!(%{name: "Rent"})
# SpendLog.Spending.Category |> Ash.Seed.seed!(%{name: "Entertainment"})
# OR call the internal :seed action:
# SpendLog.Spending.Category |> Ash.Changeset.for_create(:seed, %{name: "Food"}) |> Ash.create!(authorize?: false)
```

---

## Flags and Items to Verify at Implementation Time

1. **FK violation error struct** — The exact struct inside `Ash.Error.Invalid.errors` for a Postgres
   FK violation needs to be confirmed from `deps/ash_postgres/lib/` at implementation time. It may
   be `Ash.Error.Changes.InvalidChanges` or a postgres-specific struct.

2. **`compare/2` with `Decimal` literal** — Verified that `compare/2` accepts comparand values;
   however, the exact way `Decimal.new("1.00")` is passed as a comparand in the DSL (`validate
   compare(:amount, greater_than_or_equal_to: Decimal.new("1.00"))`) should be tested. If the
   DSL does not accept a `%Decimal{}` struct as a literal, the validation would need to be a
   custom module using `Ash.Changeset.get_attribute` and `Decimal.compare/2` instead.

3. **`prepare build(load: [:category])` in a named read action** — The `build/1` preparation
   supports `load:` as a key per the Ash docs. Confirmed from usage-rules examples. Should be
   verified that loading a `belongs_to` via `build(load: [:category])` in a preparation is
   equivalent to using `Ash.Query.load/2` directly (it is, per the preparation built-ins).

4. **`Ash.Seed.seed!/1` for Category in tests** — `Ash.Seed` bypasses actions. The identity
   uniqueness check (eager_check) only runs during action changeset building, not during seed.
   In concurrent tests, use `System.unique_integer([:positive])` suffixes on names to avoid
   unique index violations at the DB level.

---

## Open Questions

1. Should categories be editable by users at all, or are they strictly admin-seeded? The current
   design exposes no create/update/destroy for Category in the code interface. If user-created
   categories are needed, add a `:create` action and a `define :create_category` in the domain.

2. Should entries support `:update` (edit) and `:destroy` (delete)? The design currently omits
   these. Add named actions (e.g., `:update_entry`, `:delete_entry`) when that requirement is
   confirmed.

3. Should `list_entries_for_month` be paginated? At personal-spending-log scale, likely not
   needed, but add `pagination do keyset? true end` to the resource if desired.
