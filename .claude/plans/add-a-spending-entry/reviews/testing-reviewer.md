# Test Review: add-a-spending-entry

## Summary

The test suite is well-structured overall. Iron laws are mostly honoured, factories are correct, and
the six acceptance criteria each have at least one test exercising them. However several specific
tests have weaknesses that could allow a broken implementation to pass: a weak match operator on the
alphabetical-order assertion, an `assert_reply` call that is missing an import, a "fields reset"
test that proves defaults rather than reset, a hardcoded date in `month_test.exs` that will silently
stop testing anything when time advances, and missing boundary-value coverage at exactly €1.00 and
€1,000,000.00 in the LiveView layer.

---

## Iron Law Violations

None.

`async: true` is used throughout. Both `DataCase` and `ConnCase` use `Ecto.Adapters.SQL.Sandbox`
with `shared: not tags[:async]`. No Mox, no `Process.sleep`, no `insert/2` inside factory
definitions. Category names are suffixed with `System.unique_integer([:positive])` so the unique
index (`spending_categories_unique_name_index`) does not cause cross-test collisions even with
`async: true`.

---

## Issues Found

### Critical

- **`assert_reply` is undefined in the LiveView test module**
  `test/spend_log_web/live/spending_live_test.exs:137`

  `assert_reply/2` lives in `Phoenix.LiveViewTest` and must be imported. The test file imports
  `Phoenix.LiveViewTest` (line 13), so the macro is available — however `assert_reply` in
  `Phoenix.LiveViewTest` takes `(view, payload)` where `payload` is a pattern, not a plain map
  equality check. The call is:

  ```elixir
  assert_reply(view, %{reset: true})
  ```

  This form is correct *syntax* for `Phoenix.LiveViewTest.assert_reply/2`, but the macro
  pattern-matches `{^ref, {:reply, unquote(payload)}}`. If the server replies `%{reset: true,
  ...extra_keys...}` the match will fail. More importantly: `render_hook/3` is the call driving the
  submit — `assert_reply` then receives the *reply from a subsequent message*, not from the
  `render_hook` that triggered the submit. Depending on the LiveView test harness version, this may
  match a stale message or raise with a timeout.

  **Verify:** run `mix test test/spend_log_web/live/spending_live_test.exs:129` in isolation; if it
  passes only because the proxy ref matches a leftover message this test is a false positive.

  Severity: **Critical** — acceptance criterion b44b5c13da4f ("pop-up reset") depends on this test.

---

### Warnings

- **Alphabetical-order assertion uses `=` (match) not `==` (equality)**
  `test/spend_log_web/live/spending_live_test.exs:81`
  `test/spend_log/spending/entry_test.exs:169`

  Both tests write:
  ```elixir
  assert ~w(Entertainment Food Rent Transport) =
           Enum.map(props(view)["categories"], & &1["name"])
  ```
  The `=` operator is a *pattern match*, not equality. A list literal on the left side of `=` pins
  each element positionally, so this is effectively the same as `==` for a plain string list — but
  it does **not** fail if the right side contains *extra* elements after the matched prefix (pattern
  matching on a list only checks the elements listed unless a tail pattern is present). More
  practically: if the implementation returns `["Entertainment", "Food", "Rent", "Transport",
  "Zzzz"]` the assertion still passes. Because `default_categories_fixture/0` creates exactly four
  categories and no others exist in an isolated sandbox test, this is only a theoretical risk here,
  but the intent is clearly `==`. Use `assert ~w(...) == ...` to make the assertion strict and
  self-documenting.

  The fixture does insert in non-alphabetical order (`Transport Food Entertainment Rent`) which is
  correct — the ordering test *can* fail if the sort is removed.

  Severity: **Warning** — weaker assertion than intended; passes today but masks regressions.

- **"Fields reset" test proves defaults, not reset**
  `test/spend_log_web/live/spending_live_test.exs:110-127`

  The test submits one entry and then reads the form values. It asserts `amount == ""`,
  `category_id == ""`, `note == ""`, `date == today_iso()` — which are the same values the form
  starts with. If the implementation *never* reset the form at all and the values simply persisted,
  the test would still pass because amount/category/note happen to match both "unchanged" and
  "reset-to-blank". Only a test that deliberately submits non-default values *and then* checks that
  those values are gone can distinguish "was reset" from "was always blank".

  Specifically: `category_id` in the submit is the fixture's UUID (non-blank), yet the assertion
  checks `category_id == ""`. That one field *does* distinguish reset from persistence — but
  `amount` and `note` are submitted as `"12.34"` / `"Lunch"` (via `form_params` defaults which are
  overridden in the `submit/2` call at line 114 to pass `%{"amount" => "12.34", ..., "note" =>
  "Lunch"}`). Checking that `amount` reverts to `""` after a successful submit is a genuine reset
  test for that field. However, `note == ""` at line 122 is submitted as `"Lunch"` and checked for
  `""` — also a genuine delta. So `amount` and `note` do distinguish reset from no-reset; only
  `category_id` is genuinely checked. This is a partial proof. The test could be strengthened by
  explicitly noting what non-default values were submitted.

  Severity: **Warning** — test is partially tautological on `category_id` (submitted as UUID, reset
  expected as `""` — this actually does verify reset) but the structure is fragile; a reader cannot
  tell which assertions are meaningful without tracing `form_params`.

- **Hardcoded dates in `month_test.exs` will silently pass with wrong semantics after 2026-09**
  `test/spend_log/spending/month_test.exs:40-44`

  ```elixir
  mid_month = ~D[2026-09-21]

  refute Month.future?("2026-09", mid_month)
  refute Month.future?("2026-08", mid_month)
  assert Month.future?("2026-10", mid_month)
  ```

  The literal `~D[2026-09-21]` is a fixed date (today on the day of writing). The test will
  continue to compile and pass forever because it does not use `Date.utc_today()` — but it tests
  only one calendar point. This is acceptable for a pure-function unit test (it doesn't break), but
  it doesn't protect against an implementation that compares against the live clock rather than the
  supplied `mid_month` argument.

  Similar hardcoding appears in `Month.label/1` and `Month.label_date/1` tests (lines 50-56) and
  `Month.from_date/1` (lines 62-64) — those are fine since they test formatting, not time logic.

  The `future?/2` test would be stronger if it passed `Date.utc_today()` as the anchor and
  constructed relative month strings, which is what `entry_test.exs` does correctly via
  `past_month/0`.

  Severity: **Warning** — the test does not break and does not produce false passes today, but it
  cannot catch an implementation that ignores the `mid_month` argument and uses the real clock
  instead (those would only diverge after September 2026).

- **`assert_reply` in LiveView test is not imported via `import Phoenix.LiveViewTest`**
  `test/spend_log_web/live/spending_live_test.exs:137`

  The module calls `import Phoenix.LiveViewTest` (line 13) which *does* export `assert_reply/2` as
  a macro. However `SpendLogWeb.ConnCase` does **not** import `Phoenix.LiveViewTest` — only
  `Phoenix.ConnTest` and `Phoenix.ConnTest` are imported in the `using` block. The file therefore
  relies on its own `import Phoenix.LiveViewTest` at line 13 being in scope. This is fine, but if
  the import is ever reorganised the call silently breaks. Consider adding `assert_reply` to the
  ConnCase `using` block, or at minimum add a comment noting the dependency.

  Severity: **Warning** (no current breakage).

---

### Suggestions

- **Missing LiveView-layer boundary tests for exactly €1.00 and €1,000,000.00**
  `test/spend_log_web/live/spending_live_test.exs`

  `entry_test.exs:53-56` covers the inclusive bounds at the domain level. The LiveView tests only
  probe `0.99` (below min) and `1000000.01` (above max) — the boundary values themselves (`1.00`
  and `1000000.00`) are not exercised through the LiveView submit path. An off-by-one in the
  AshPhoenix form-to-resource parameter coercion (e.g. decimal precision) would not be caught.
  Suggest adding two cases alongside the existing tests at lines 172-190.

- **No test that "today is accepted" through the LiveView submit path**
  `test/spend_log_web/live/spending_live_test.exs`

  `entry_test.exs:83` tests today at the domain layer. The LiveView tests submit today's date
  implicitly (the default `form_params` sets `"date" => today_iso()`), but no test explicitly names
  "today is accepted" as an assertion. The "accepts a past date" test at line 150 demonstrates
  navigation but does not re-assert the base case. Not a gap in coverage per se, but the intent
  mapping to acceptance criterion is opaque.

- **`errors_for/2` in `entry_test.exs` uses `Map.get(&1, :field)` on Ash error structs**
  `test/spend_log/spending/entry_test.exs:28-31`

  The helper accesses both `:field` and `:fields` (plural) to catch Ash errors. This is defensively
  correct but untested — if Ash changes its error shape the helper silently returns `[]` and the
  assertions that follow would fail with a confusing "expected string in list, got empty list"
  message rather than a clear structural error. A guard `assert is_list(errors)` before the `in`
  check would surface this faster.

- **`default_categories_fixture/0` uses `category_fixture(name: ...)` which calls `create_category!/1`**
  `test/support/spending_fixtures.ex:38-40`

  Because it creates named categories without a uniqueness suffix, two tests in the same sandbox
  that both call `default_categories_fixture/0` would collide on the unique name index. The
  alphabetical-order tests (`spending_live_test.exs:76-83` and `entry_test.exs:167-170`) each call
  it once in an isolated sandbox, so no collision occurs in practice. But the fixture docstring
  should warn callers not to call it more than once per test, or the fixture itself should be
  idempotent (upsert).

- **`monthly_summary/2` test in `entry_test.exs` uses `Enum.at/2` after a pattern match**
  `test/spend_log/spending/entry_test.exs:150-153`

  ```elixir
  assert [%{category_name: "Food"}, %{category_name: "Rent"}] = summary.rows
  assert Decimal.equal?(Enum.at(summary.rows, 0).total, Decimal.new("20.00"))
  assert Decimal.equal?(Enum.at(summary.rows, 1).total, Decimal.new("900.00"))
  ```

  The first line binds the rows positionally by pattern match (correct), then the next two lines
  re-index by position. If the sort order ever changed the pattern match would fail (good), but the
  `Enum.at` calls are redundant — the totals could simply be bound in the first assertion:
  `[%{category_name: "Food", total: food_total}, ...]`. Minor style issue, not a correctness bug.
