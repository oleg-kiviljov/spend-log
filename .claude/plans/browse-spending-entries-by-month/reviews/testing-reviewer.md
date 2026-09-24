# Test Review: Browse Spending Entries by Month

## Summary

The test suite is well-structured overall — async-safe, uses `LiveVue.Test.get_vue/2` instead of raw HTML matching, no `Process.sleep`, all database tests go through the Sandbox via `ConnCase`. However there are several substantive issues: one assertion is vacuous (passes for the wrong reason), `refute_push_event` is unreliable in both tests that use it, criterion 723530cc5220 has four of its six clauses untested, and two tests have mild but real time-dependence.

---

## Iron Law Violations

None.

---

## Issues Found

### Critical

- **`refute_push_event` is unreliable — both tests that use it can pass spuriously.**

  `refute_push_event/3` (from `Phoenix.LiveViewTest`) asserts that no matching event is in the buffer *at the moment the call executes*. Because `push_event` is delivered asynchronously to the test process, calling `refute_push_event` immediately after the `render_hook` calls in "does not jump to the top when the navigation was refused" (line 140) and "refuses every navigation while nothing has ever been recorded" (line 228) can pass even if the server *did* push `scroll_to_top`, simply because the message has not arrived yet. The reliable pattern is:

  ```elixir
  # drain any events that did arrive, then assert none matched
  refute_receive {:push_event, "scroll_to_top", _}, 100
  ```

  This is a correctness issue, not just style: these two tests are supposed to be the *enforcement* that refused navigations do not scroll. A spurious pass hides a regression.

- **`assert month["earliest"] == nil` is vacuous (line 213, "shows the placeholder and offers no arrows when nothing was ever recorded").**

  `props(view)["month"]` returns a decoded JSON map with string keys. `Map.get(map, "earliest")` returns `nil` both when the key is absent *and* when it is present with value `nil`. The assertion passes even if the server never sends the `earliest` key at all. The test should instead assert that the key is explicitly present with value `nil`:

  ```elixir
  assert Map.has_key?(month, "earliest")
  assert month["earliest"] == nil
  ```

  Or, equivalently, pattern-match the whole map to assert its shape.

### Warnings

- **Criterion 723530cc5220 — four of six clauses are not asserted.**

  The criterion has six named behaviours. Tests cover: (a) only selected month's entries, (b) newest-first, (c) "January 2025" header format. The following are not covered by any assertion:

  1. **"Jump to top of list on navigation"** — the `assert_push_event` in "jumps the list back to the top on each navigation" (line 124–127) only checks that the event was pushed. It does not verify the *absence* of a jump when already on the target month (a no-op re-navigation). More importantly the test navigates to months that already have data; a navigation that results in an *empty* month should also emit the event (there is no test for that).

  2. **"Forward blocked at current month"** — tested in `describe "browsing by month"` (line 144) and also in `describe "select_month"` (line 508), so this is covered. ✓

  3. **"Back blocked at earliest entry"** — tested in line 159. ✓

  4. **"Placeholder when nothing ever recorded"** — tested in line 205. ✓

  5. **The scroll event is emitted on the *first* navigation away from the current month** — the `assert_push_event` test (line 119) navigates to past months with fixtures; there is no test confirming the event fires when navigating from `this_month()` to any past month (a common first user action).

  6. **`prev`/`next` prop wiring after navigation** — after `go_to(view, @january)` the test checks `month_of(view)["prev"] == nil` and `month_of(view)["next"] == "2025-02"`. This is tested in the `1cb6c8f0c344` block (line 168–170). ✓

  Summary: the scroll-on-navigation path through an empty month and the first-navigation-away-from-current-month case are not covered.

- **Time-dependence in "refuses to page forward past the current month" (line 144).**

  `this_month()` and `next_month()` are computed at call time via `Date.utc_today()`. The test passes an `entry_fixture(date: Date.utc_today())` so the earliest month is the current month. If this test runs within a few milliseconds of a month boundary, `Date.utc_today()` in `entry_fixture`, `this_month()`, and `next_month()` could return values from two different months, causing the "forward blocked" assertion on `month_of(view)["is_current"] == true` to fail (because `is_current` is computed from the `today` captured at `mount`, which may already be the new month). Low probability but possible in CI.

- **`next_month()` helper uses `Date.shift(month: 1)` on a date (line 31), then `Month.from_date/1`.**

  This is correct, but the result is also used in the "refuses every navigation while nothing has ever been recorded" test (line 223): `for month <- [@january, "2024-12", this_month()]`. Notice `next_month()` is NOT in this loop — the test does not try to navigate to a future month in the empty-history case. Since `navigable?/2` returns `false` for `earliest_month: nil` unconditionally, this is technically already covered, but the omission of a future-month attempt in that loop is a minor coverage gap worth noting.

- **`assert_push_event` called without capturing the return value (lines 124, 127).**

  `Phoenix.LiveViewTest.assert_push_event/3` returns the matched payload. Not capturing it is fine if the payload is not examined, but for `scroll_to_top` the payload is always `%{}`, so there is nothing further to assert. This is not a bug but is inconsistent with the project's usual assertion depth.

### Suggestions

- **`month_test.exs` — `before?/2` tests are well-formed.** No issues. The three new `describe "before?/2"` tests correctly cover equal months (reflexive case), within-year ordering, and year-boundary ordering. The `before?/2` implementation is a bare `<` on strings, so these tests are the only guard against someone changing that to something wrong.

- **`january_history()` correctly inserts entries out of date-order** (lines 43–53), which is the right approach for making the newest-first assertion meaningful. No issue.

- **The `entry_on/3` helper (line 37) re-uses a passed category, avoiding extra DB inserts.** Correct pattern.

- Consider extracting the `assert_push_event` + `refute_push_event` pattern into a named helper once it appears in more than two places, so the reliable `assert_receive`/`refute_receive` version is used consistently.
