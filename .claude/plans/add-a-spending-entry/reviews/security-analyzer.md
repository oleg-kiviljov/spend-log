# Security Audit: SpendLog — "Add a spending entry"

Scope: the client-facing attack surface of the new feature. Authentication and Ash policies
are deliberately absent (plan.md decision 4) and are not reported as findings.

## Executive summary

No injection, no atom exhaustion, no XSS, no mass assignment, no unsafe deserialisation. The
input-validation story on the *values* is genuinely good — `Month.parse/1` is a strict
anchored regex, every query pins with `^`, `accept` is a tight allow-list, and every Vue
binding is a mustache.

What is missing is validation of the payload **shape** and any bound on **volume**. Three of
the four `handle_event/3` clauses crash the LiveView process on a payload the Vue client
never sends, and there are three unbounded-work paths an attacker reaches with one event.

| # | Finding | Severity |
|---|---|---|
| 1 | Non-map `"form"` param crashes `validate`/`submit` (`BadMapError`) | Medium |
| 2 | Missing-key payloads crash three of four events (`FunctionClauseError`) | Low |
| 3 | Unbounded month entry list — O(N) DB + CPU + wire per event, no stream | Medium |
| 4 | One DB query per `validate` event, unthrottled | Low |
| 5 | Unbounded inbound frame retained in assigns and echoed back | Low |
| 6 | No index on `spending_entries.date` — seq scan per `load_month/1` | Low |
| 7 | `Month.previous` can emit `"0000-12"`, which `Month.parse` then rejects | Info |
| 8 | Session cookie has no explicit `secure`/`http_only` | Info |

**On the requested crash hunt for `select_month`: I could not construct one.** Details under
"Checks that came back clean". The crash I *did* find is on `validate`/`submit`.

---

## Critical / High

None.

---

## 1. Non-map `"form"` param crashes the LiveView (Medium)

- **Severity**: Medium (availability only — no data exposure, no integrity loss)
- **Location**: `lib/spend_log_web/live/spending_live.ex:67-68` and `:73-74`
- **OWASP**: A04:2021 Insecure Design

`handle_event("validate", %{"form" => params}, …)` matches the *key* but never the *shape*.
A client can push `validate` with `{"form": "pwn"}`, `{"form": ["pwn"]}` or `{"form": 1}` —
`render_hook`/`pushEvent` will happily send any JSON.

Traced through `deps/ash_phoenix/lib/ash_phoenix/form/form.ex`:

1. `validate/3` line 1333 — `opts[:only_touched?]` is nil (never passed), so the `Map.take`
   guard is skipped.
2. line 1344 — `strip_array_empty_values/2` has an explicit catch-all clause at `form.ex:6205`
   (`defp strip_array_empty_values(_form, params), do: params`) that passes non-maps through
   untouched.
3. line 1346 — `form.prepare_params` is nil (LiveVue's `prepareData` in
   `AddEntryModal.vue:37` is client-side JS, not a server hook), so no coercion there either.
4. line 1384 — `validate_nested_forms/6`; this form has no nested forms, so `form.form_keys`
   is `[]`, the reduce is a no-op, and `changeset_params` comes back as the attacker's
   non-map value verbatim.
5. line 1415 — `Ash.Changeset.for_create(form.action, Map.drop(changeset_params,
   ["_form_type", "_touched", "_union_type"]), …)`. `Map.drop/2` on a binary or list raises
   `BadMapError`.

The LiveView process dies, Phoenix logs a full stacktrace, the client reconnects and can
repeat immediately. Looped, this is log-volume + process-churn DoS. `submit` reaches the
same line via `form.ex:2178-2182`, which calls `validate/3` with `opts[:params]`.

**Fix** — validate shape at the boundary (Iron Law #1), on both events:

```elixir
def handle_event("validate", %{"form" => params}, socket) when is_map(params) do
  form = AshPhoenix.Form.validate(socket.assigns.form.source, params)
  {:noreply, socket |> assign(:form, to_vue_form(form)) |> assign(:form_error, nil)}
end

def handle_event("submit", %{"form" => params}, socket) when is_map(params) do
  …
end
```

## 2. Missing-key payloads raise `FunctionClauseError` (Low)

- **Severity**: Low
- **Location**: `lib/spend_log_web/live/spending_live.ex:67, 73, 109`

`{"validate": {}}`, `{"submit": {}}` and `{"select_month": {}}` match no clause of
`handle_event/3`. LiveView raises `FunctionClauseError` and the process dies. Same blast
radius as #1. `"open_entry_form"` (`:98`) is the only total clause.

**Fix**: add a trailing ignore clause after the typed ones, e.g.

```elixir
def handle_event(event, _params, socket)
    when event in ~w(validate submit select_month) do
  {:noreply, socket}
end
```

The existing test suite covers hostile *values* (`spending_live_test.exs:281`
`"not-a-month"`, `:223` `category_id => nil`) but never a hostile payload *shape* — that is
exactly the gap findings #1 and #2 sit in.

## 3. Unbounded month entry list (Medium)

- **Severity**: Medium
- **Location**: `lib/spend_log_web/live/spending_live.ex:125-135`;
  `lib/spend_log/spending/entry.ex:71-79`; `lib/spend_log/spending.ex:61-75`
- Also an **Iron Law #2 violation** (streams for lists > 100 items) — `:entries` is a plain
  assign rendered via `Enum.map` at `spending_live.ex:55`.

`:list_for_month` has no `limit` and no pagination. `load_month/1` runs on connected mount,
on every successful `submit`, and on every accepted `select_month`. Each run:

- reads **every** entry in the month (`FilterByMonth` has no bound),
- folds `Spending.summarize/1` over the full list in memory (`group_by` + two traversals),
- projects every row into a prop map which LiveVue encodes and pushes over the wire.

N is attacker-controlled and monotonically increasing: every `submit` adds a row, and every
subsequent event pays for it — O(N) rows + O(N) CPU + O(N) bytes, forever. There is no cap
on entries per month anywhere in the resource.

**Fix**: bound the read (`Ash.Query.limit/2` or keyset pagination on `:list_for_month`),
compute the summary as a DB-side aggregate rather than folding the whole list, and render
through `stream/3` with `phx-update="stream"`.

## 4. One database query per `validate` event, unthrottled (Low)

- **Severity**: Low
- **Location**: `lib/spend_log/spending/entry/validations/category_exists.ex:24`;
  `lib/spend_log_web/live/spending_live.ex:67`

Ash runs action validations at `for_create` time, so every `validate` event with a
cast-able `category_id` issues an `Ash.exists?` SELECT against `spending_categories`. The
300 ms debounce lives in the client (`AddEntryModal.vue:35`) and an attacker simply does not
use it — `pushEvent("validate", …)` in a tight loop is one SELECT per message, with no rate
limiting anywhere in the app.

The validation itself is correct and well-reasoned (its moduledoc is right that the FK is
the real guarantee). The issue is purely the absence of a throttle. Consider a `Hammer`
limit on the socket, or short-circuiting `CategoryExists` when the rest of the changeset is
already invalid (`only_when_valid?`).

## 5. Unbounded inbound frame retained and echoed (Low)

- **Severity**: Low
- **Location**: `lib/spend_log_web/endpoint.ex:15-17`;
  `lib/spend_log_web/live/spending_live.ex:67-70`

The `socket "/live"` declaration sets no `max_frame_size`, and Phoenix's documented default
is `:infinity` (`deps/phoenix/lib/phoenix/endpoint.ex:1018-1019`). A single `validate` frame
carrying a 50 MB `note` is accepted, stored in `socket.assigns.form` (AshPhoenix retains
both `raw_params` and `params`), and then **echoed straight back to the client**: LiveVue's
`Phoenix.HTML.Form` encoder serialises `values` out of the form params
(`deps/live_vue/lib/live_vue/encoder.ex:123-132` and `:243-245`).

`max_length: 500` on `:note` (`entry.ex:95-98`) rejects the *save*, but it runs after the
string is already resident in the BEAM — it protects Postgres, not memory.

**Fix**:

```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [session: @session_options], max_frame_size: 64_000],
  longpoll: [connect_info: [session: @session_options]]
```

## 6. No index on `spending_entries.date` (Low)

- **Severity**: Low
- **Location**: `priv/repo/migrations/20260921024929_add_spending_domain.exs:11-26`

The migration creates only the two primary keys and
`spending_categories_unique_name_index`. `FilterByMonth` filters
`date >= ^first and date <= ^last` (`filter_by_month.ex:20`) with nothing to support it, so
every `load_month/1` sequentially scans the whole table. This multiplies finding #3.

**Fix**: add to `SpendLog.Spending.Entry`

```elixir
postgres do
  table "spending_entries"
  repo SpendLog.Repo

  custom_indexes do
    index [:date]
  end
end
```

then `mix ash.codegen add_entry_date_index && mix ash.migrate`.

## 7. `Month.previous` can produce a string `Month.parse` rejects (Info)

- **Location**: `lib/spend_log/spending/month.ex:44` vs `:83-90`

`parse/1` enforces `year > 0`, but `shift/2` does not enforce that bound on its *output*:
`Month.previous("0001-01")` → `Date.new!(1, 1, 1) |> Date.shift(month: -1)` →
`~D[0000-12-01]` → `"0000-12"`. That value is handed to the client as `month.prev`
(`spending_live.ex:183`) and wired to the "Previous month" button
(`MonthSwitcher.vue:35`); clicking it pushes `select_month` with `"0000-12"`, which
`parse/1` rejects and `handle_event` silently ignores. A dead control, not a crash — and
only reachable by first selecting `"0001-01"` by hand.

Related note on the bang-matches: `load_month/1` (`spending_live.ex:126`), `label/1`
(`month.ex:73`) and `shift/2` (`month.ex:84`) all do `{:ok, {y, m}} = parse(...)`. These are
safe **only** because `@month` is seeded from `Month.from_date/1` at mount and is never
reassigned without a successful `parse/1` first (`spending_live.ex:112-117`). That invariant
is load-bearing, currently undocumented, and one careless `assign(:month, …)` away from
becoming a `MatchError`. Worth a comment on the assign.

## 8. Session cookie flags (Info)

- **Location**: `lib/spend_log_web/endpoint.ex:8-13`

`@session_options` sets `same_site: "Lax"` but not `secure: true` (`http_only` defaults to
true in `Plug.Session`). The session currently carries nothing sensitive, and
`force_ssl` is on in prod (`config/prod.exs:14-21`, which implies HSTS via `Plug.SSL`'s
`hsts: true` default), so the practical risk is nil. Set `secure: true` if a session ever
starts holding anything.

---

## Checks that came back clean

Each of these was verified against the actual code, not assumed:

- **Atom exhaustion (Iron Law #7)** — zero `String.to_atom/1` or `to_existing_atom/1` calls
  in `lib/` or `assets/`. AshPhoenix's own param→field conversion goes through a
  `safe_existing_atom/1` helper (`form.ex:6228`), so client keys never mint atoms.
- **SQL injection (Iron Law #5)** — every query is an Ash expression with pinned values:
  `filter_by_month.ex:20` (`date >= ^first and date <= ^last`) and `category_exists.ex:24`
  (`id == ^category_id`). No `fragment` with interpolation, no `Repo.query`, no raw SQL
  outside generated migrations.
- **Mass assignment** — `Entry.create` accepts exactly `[:amount, :date, :note,
  :category_id]` (`entry.ex:52`). AshPhoenix passes
  `skip_unknown_inputs: Map.keys(changeset_params)` (`form.ex:2479-2482`), so extra client
  keys — `id`, `inserted_at`, `updated_at`, or a `category` relationship payload — are
  silently dropped rather than cast. `attribute_writable? true` on the `belongs_to`
  (`entry.ex:107`) is deliberate and is the intended input. `Category.create` accepts only
  `[:name]` and is not reachable from the LiveView at all.
- **XSS (Iron Law #9)** — no `raw/1` in any HEEx, no `v-html`/`innerHTML` in any `.vue`.
  User-supplied text renders through escaped interpolation everywhere: the `note` at
  `SpendingList.vue:36`, category names at `SpendingList.vue:31` (`UBadge :label`) and
  `MonthlySummary.vue:34`. The one dynamic `:style` binding (`MonthlySummary.vue:42`) takes
  a server-computed integer from `share/2` (`spending_live.ex:208-218`), not a string.
- **`select_month` crash hunt** — `Month.parse/1` (`month.ex:39-51`) is an anchored
  `^(\d{4})-(\d{2})$` with `year > 0 and month in 1..12` and a non-binary catch-all clause.
  Consequences:
  - `"0000-01"` → rejected by `year > 0`.
  - `"9999-12"`, `"2099-01"` and every other far-future value → parses, then refused by
    `Month.future?/2` (`spending_live.ex:114`) before `load_month/1` runs, so `@month` is
    never assigned.
  - The 4-digit cap means `Date.new(year, month, 1)` in `FilterByMonth` can only ever see
    year 1..9999 — all valid ISO dates — so its `{:error, _}` branch is
    unreachable-but-correct, and the `{:ok, {y, m}} = parse(...)` in `load_month/1` cannot
    raise.
  - Year-overflow in `Date.shift` is unreachable: `Month.next/1` is only ever called on
    `@month` (`spending_live.ex:177`), which is bounded above by the current month.
  - Non-binaries (`{"month": {"a": 1}}`, `{"month": 7}`, `{"month": null}`) hit
    `parse(_value), do: :error`.
  A malformed `select_month` value cannot crash the LiveView or produce a pathological
  query. The only reachable crash on this event is the missing-key case (finding #2).
- **Money / Iron Law #4** — `Decimal` end to end; `:decimal` attribute with
  `precision: 12, scale: 2`; bounds enforced by two `compare` validations
  (`entry.ex:58-64`); formatting happens server-side in `SpendLog.Spending.Money` so no
  amount ever touches a JS float.
- **CSRF and security headers** — `:protect_from_forgery` and `:put_secure_browser_headers`
  are both in the `:browser` pipeline (`router.ex:11-12`), and the app's only route is
  inside it (`router.ex:19-23`).
- **Dev-only routes** — LiveDashboard, the Swoosh mailbox and the Oban dashboard sit behind
  `Application.compile_env(:spend_log, :dev_routes)` (`router.ex:31`); `dev_routes: true` is
  set only in `config/dev.exs:71`, so they compile out of prod. `Tidewave` is behind
  `Mix.env() == :dev` (`endpoint.ex:33-35`).
- **Secrets** — no hardcoded secret in `lib/`. `secret_key_base` comes from the environment
  in `config/runtime.exs:60`; the literals in `config/dev.exs:28` and `config/test.exs:25`
  are the standard non-production generator values.
- **Unsafe deserialisation / command execution** — no `binary_to_term`, no `System.cmd` or
  `:os.cmd` outside `test/build_entrypoint_gate_test.exs`, no `Code.eval_*`.
- **File / path handling** — the feature reads and writes no files; no upload surface.

## Caveat on verification method

This audit ran with read-only tools (no shell), so findings #1 and #2 are proven by tracing
dependency source line-by-line rather than by executing a crashing payload, and nothing in
the tree was modified. To confirm #1 empirically, add to
`test/spend_log_web/live/spending_live_test.exs`:

```elixir
test "hostile validate payload does not crash the LiveView", %{view: view} do
  render_hook(view, "validate", %{"form" => "pwn"})
  assert props(view)["month"]
end
```

Expected today: `** (BadMapError) expected a map, got: "pwn"` from
`AshPhoenix.Form.validate/3`. The same with `render_hook(view, "select_month", %{})` should
raise `FunctionClauseError`.

## Tools to run manually (this agent has no shell)

- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix hex.audit`
- `mix test` — to confirm the two crash reproductions above
