# Iron Law Violations Report

## Summary

- Files scanned: 11 (.ex/.exs/.vue)
- Iron Laws checked: 13 of 26 (LiveView 1–3, Ecto 4–6, Security 7–9, OTP 10, plus Law 17 re: bare `{:error, _}`)
- Violations found: 1 critical (WARNING), 1 medium (SUGGESTION), 1 low (INFO)

---

## Critical Violations

### [#2 / Ash override] Entries assigned as plain list, not stream

- **File**: `lib/spend_log_web/live/spending_live.ex:38` and `spending_live.ex:128–130`
- **Code**:
  ```elixir
  |> assign(:entries, [])            # mount
  |> assign(:entries, entries)       # load_month/1
  ```
  The entries are then mapped in `render/1` via `Enum.map(@entries, &entry_prop/1)` and passed as a
  plain JSON array prop to the Vue component.
- **Confidence**: LIKELY — violation is real for the hard floor (>100 items); defensibility depends on expected data volume
- **Assessment**: CLAUDE.md's Ash override says _"always use streams for collections"_ with >100 as
  the hard floor, not a licence to use assigns for smaller ones. The entries list is unbounded: a user
  who logs daily for years will have hundreds of entries per month. There is no pagination or cap.
  A plain `assign` means every connected socket holds a full copy of the month's entries in memory,
  and a re-render diffs the entire list.

  **Fix**: Switch to a LiveView stream and pass the entries differently. Because this is a LiveVue
  island rather than a HEEx list, the entries cannot be streamed directly into the Vue prop (streams
  are HEEx-only constructs). The correct pattern for a LiveVue island with a large list is either
  (a) paginate / cap the result set in `list_entries_for_month!` and keep a plain assign, or (b)
  split the list into a server-rendered HEEx table that uses a stream and keep the Vue island only
  for the form. Option (a) is the practical path here: cap the month at a reasonable maximum (e.g.
  500 entries) and document the invariant, which is far more than any real user will have in a month.
  This converts the memory risk from unbounded to bounded and satisfies the spirit of the law.

---

## Medium Violations

### [#8] `select_month` sanitises the month value, but the guard has a subtle type mismatch

- **File**: `lib/spend_log_web/live/spending_live.ex:109–123`
- **Code**:
  ```elixir
  def handle_event("select_month", %{"month" => month}, socket) do
    case Month.parse(month) do
      {:ok, _year_and_month} ->
        if Month.future?(month, socket.assigns.today) do
  ```
  `Month.parse/1` returns `{:ok, {year, month_number}}` on success but the bound variable
  `_year_and_month` is discarded. The code then calls `Month.future?/2` with the raw client string
  `month` and subsequently assigns that same raw string with `assign(:month, month)`. This is fine
  _if_ `Month.parse` already validated the string — and it does — but the assign stores the raw
  client value rather than a normalised form. For `"2026-09"` that is harmless; for a string like
  `"2026-9"` it would be rejected by `parse/1` first and never reach the assign, so there is no
  actual injection path. However, the intent of returning `{year, month_number}` from `parse/1` was
  presumably to use the parsed, canonical form downstream.
- **Confidence**: REVIEW — not a security hole because the parse guard runs first; a style concern
  that could become a bug if `Month.future?/2` or `Month.label/1` are ever called with unvalidated
  input via a different code path.
- **Fix**: Use the parsed values rather than re-using the raw string:
  ```elixir
  case Month.parse(month) do
    {:ok, {year, month_number}} ->
      canonical = "#{year}-#{String.pad_leading(to_string(month_number), 2, "0")}"
      if Month.future?(canonical, socket.assigns.today) do
        {:noreply, socket}
      else
        {:noreply, socket |> assign(:month, canonical) |> load_month()}
      end
    :error ->
      {:noreply, socket}
  end
  ```
  Or, simpler: have `Month.parse/1` also return the canonical string form so callers do not need to
  reconstruct it.

---

## Passing Checks (abbreviated — no padding)

**Law 1 (no DB in disconnected mount)**: CLEAN. `mount/3` assigns only static values and an empty
summary. The `connected?` guard on line 43 gates all DB work (`load_month/1`) to the connected
render only. No `Repo.*` or Ash reads in the disconnected branch.

**Law 3 (connected? before PubSub)**: CLEAN. No PubSub subscriptions in this feature.

**Law 4 (no :float for money)**: CLEAN. `amount` is `:decimal` on the Ash attribute
(`entry.ex:85`), stored with `precision: 12, scale: 2`. Money never crosses the JSON boundary as
a number: `entry_prop/1` serialises it through `Money.to_eur/1` into a display string, and
`summary_prop/1` does the same. The Vue types file and components only see `amount_display` (a
string). The amount input in `AddEntryModal.vue` is `type="text"` / `inputmode="decimal"` — it
never passes through `parseFloat`. Iron Law #4 is satisfied end to end.

**Law 5 (pin values in queries)**: CLEAN. `FilterByMonth` uses `^first` and `^last` in
`Ash.Query.filter`. `CategoryExists` uses `^category_id`. No string interpolation found in any
query.

**Law 6 (separate queries for has_many, JOIN for belongs_to)**: CLEAN. The `:category`
relationship is `belongs_to`; `list_for_month` uses `prepare build(load: [:category])` which Ash
resolves as a JOIN. No has_many associations are loaded here.

**Law 7 (no String.to_atom on user input)**: CLEAN. No `String.to_atom/1` calls found anywhere in
`lib/`.

**Law 8 (authorize every handle_event)**: CONTEXT NOTE. There is no authentication in this app —
no `current_user`, no sessions beyond the LiveView connection, no multi-tenancy. Under those
conditions "authorize every handle_event" means "validate and sanitise all client-supplied values
before acting on them":

- `validate`: delegates to `AshPhoenix.Form.validate/2`; the form's declared inputs are the trust
  boundary — arbitrary keys cannot be injected.
- `submit`: same — `AshPhoenix.Form.submit/2` casts only accepted attributes (`:amount`, `:date`,
  `:note`, `:category_id`).
- `open_entry_form`: takes no params; rebuilds a blank form.
- `select_month`: the `month` string is parsed by `Month.parse/1` with a strict regex before use,
  and a future-month guard prevents acting on an out-of-range value.

All four clauses are CLEAN for the no-auth context. If authentication is added later, each
`handle_event` will need an ownership/scope check.

**Law 9 (no raw/1 with untrusted content)**: CLEAN. No `raw(` calls found in any `.ex` or `.heex`
file. Vue templates use `{{ }}` interpolation (auto-escaped by Vue's renderer) throughout; no
`v-html` directives are present.

**Law 10 (no process without runtime reason)**: CLEAN. No bare `GenServer`, `Agent`, or `Task`
spawns found. LiveView itself is a supervised process.

**Law 17 (match {:error, %Ecto.Changeset{}} explicitly)**: CLEAN. The `submit` handler matches
`{:error, form}` where `form` is the `AshPhoenix.Form` struct returned by `AshPhoenix.Form.submit/2`
on failure (not a bare `{:error, _}` that would swallow a changeset). The matched value is
immediately passed to `to_vue_form/1` and `form_level_error/1`, so changeset errors reach the UI.

---

## Low / INFO

**Comment style**: Several comments in `spending_live.ex` narrate implementation decisions that
belong in the commit message rather than the source (e.g. line 78–80 explaining the `reset: true`
LiveVue reply path, line 92 explaining category refresh rationale, line 99–101 explaining
`open_entry_form` behaviour). These are borderline — they describe non-obvious interactions and
footguns a future reader genuinely needs (the LiveVue form reset semantics are opaque without
them). Flagging as LOW/INFO rather than a violation; keep the footgun warnings, consider moving
the pure rationale prose to the commit message.

Checked 13 of 26 Iron Laws. 1 LIKELY violation (plain assign for unbounded list), 1 REVIEW note
(raw client string stored in assign after parse), 1 INFO note (comment style).
