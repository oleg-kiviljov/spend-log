# Plan — Add a spending entry

**Slug:** `add-a-spending-entry` · **Depth:** research it (HIGH complexity) · **Stack:** Phoenix + Ash + LiveView + LiveVue + Vue + Nuxt UI

## Discovery summary

The repo is a **fresh scaffold**: `config :spend_log, ash_domains: []`, no Ash resources, no domain
folders, `/` routed at the throwaway `SpendLogWeb.ExampleLive` + `assets/vue/ExampleForm.vue`.

Because there is no prior domain code, the `phoenix-patterns-analyst` (codebase patterns) and
`hex-library-researcher` (library selection) agents were **deliberately skipped** — there are no
existing contexts to mine for conventions and no library decision to make (ash, ash_postgres,
ash_phoenix, live_vue and @nuxt/ui are already pinned in `mix.exs` / `package.json`). The two agents
that *did* have something to analyse were run:

| Agent | Report |
|---|---|
| `phx:ash-resource-designer` | `research/ash-resource-designer-report.md` |
| `livevue-ui-architect` (MANDATORY for UI surfaces) | `research/livevue-ui-architect-report.md` |

Complexity score: **8 / 10** (new domain + 2 resources + migration + 5 custom validations/
preparations + full-stack UI with a modal form + 6 acceptance criteria). → deep planning.

## Decisions taken on top of the research (where I overruled a report)

1. **`Category` gets `create` and `destroy` actions.** The Ash report exposed read-only. Criterion
   `b7947ce9857f` ("category no longer present") is only testable if a category can actually be
   removed, and seeding the default set (TRM-004) needs a create. Both are real domain capabilities.
2. **A custom `CategoryExists` validation, not just the FK.** The report argued the Postgres FK is
   the right mechanism. It is — for *integrity*. But the criterion demands a **specific message on
   the `category_id` field**, and an FK violation surfaces as a field-less constraint error that the
   LiveVue encoder would key under `null` (report §3.8). So: keep the FK as the integrity guard,
   and add an action-level validation for the user-visible message. The TOCTOU window the report
   worried about is still closed by the FK.
3. **No `on_delete: :restrict`.** TRM-005 (a deleted category's entries become *Uncategorized*)
   means category deletion must stay possible in a later milestone; `:restrict` would have to be
   undone. The AshPostgres default FK is left in place.
4. **No policies / no `Ash.Policy.Authorizer`.** Agreed with the report: there is no authentication
   in this app, so a policy block with no actor is theatre. Iron Law #8 is still honoured — every
   `handle_event/3` validates and sanitises its payload (strict month regex, no `String.to_atom`),
   and no handler trusts a client-supplied id without the server re-checking it.

## Backend (Ash)

- [ ] **B1** `lib/spend_log/spending.ex` — `SpendLog.Spending` domain, `extensions: [AshPhoenix]`,
      code interfaces: `list_categories`, `create_category`, `delete_category`, `create_entry`,
      `list_entries_for_month`. Plus the plain `monthly_summary/2` function (a plain function, not a
      generic action — none of Ash's five reasons to prefer an action apply).
- [ ] **B2** `lib/spend_log/spending/category.ex` — table `spending_categories`, `name` required,
      `identity :unique_name` (INV-022), primary read `prepare build(sort: [name: :asc])`
      (alphabetical list), `@derive {LiveVue.Encoder, only: [:id, :name]}`.
- [ ] **B3** `lib/spend_log/spending/entry.ex` — table `spending_entries`, `amount` `:decimal`
      `constraints: [precision: 12, scale: 2]` (Iron Law #4 — never `:float`), `date` `:date`,
      `note` optional, `belongs_to :category` `allow_nil?: false` (INV-019),
      `@derive {LiveVue.Encoder, only: [:id, :amount, :date, :note, :category_id]}` (never the
      relationship — an unloaded `belongs_to` encodes as `%Ash.NotLoaded{}`).
- [ ] **B4** `create` action validations, each with the exact user-visible message:

      | Criterion | Field | Mechanism | Message |
      |---|---|---|---|
      | `9894fa7e321e` | `amount` | `compare(greater_than_or_equal_to: Decimal.new("1.00"))` | the minimum allowed amount is €1.00 |
      | `af0c9f158f8a` | `amount` | `compare(less_than_or_equal_to: Decimal.new("1000000.00"))` | the maximum allowed amount is €1,000,000.00 |
      | `300b5b0d6fd6` | `date` | custom `DateNotFuture` | cannot be in the future … |
      | `087d6b223af9` | `category_id` | `present(:category_id)` | please select a category |
      | `b7947ce9857f` | `category_id` | custom `CategoryExists` | the selected category no longer exists … |

      Literal `€1.00` / `€1,000,000.00` go **in the message string** — LiveVue's `translate_errors/1`
      only interpolates `%{}` placeholders when the matching `opts` are supplied, and no gettext
      backend is configured for live_vue.
- [ ] **B5** `lib/spend_log/spending/entry/validations/date_not_future.ex` — `compare/2` cannot take
      a runtime comparand, so this is a justified custom module. Create-only ⇒ no `atomic/3` needed
      despite `default_actions_require_atomic?: true`.
- [ ] **B6** `lib/spend_log/spending/entry/validations/category_exists.ex` — see decision 2.
- [ ] **B7** `lib/spend_log/spending/entry/preparations/filter_by_month.ex` — month bounds are
      computed from runtime arguments, so `build(filter: …)` cannot express them.
- [ ] **B8** `lib/spend_log/spending/money.ex` — EUR/date formatting (`€12.34`, `21 Sep 2026`,
      `September 2026`) in **Elixir**. Non-negotiable: prod SSR is QuickBEAM, which ships no
      `Intl.NumberFormat`/`Intl.DateTimeFormat` (report §0), and a `Decimal` must never become a JS
      float (Iron Law #4). Lives in the domain folder — it serves exactly one domain.
- [ ] **B9** Register `config :spend_log, ash_domains: [SpendLog.Spending]`; `mix ash.codegen
      add_spending_domain && mix ash.migrate`. Never hand-write the migration.
- [ ] **B10** Seed the default category set (Food, Transport, Rent, Entertainment — TRM-004) in
      `priv/repo/seeds.exs`, idempotently.

## Frontend (LiveVue + Vue + Nuxt UI)

### Component breakdown — all new, all `assets/vue/`, all `<script setup lang="ts">`

| File | Role |
|---|---|
| `SpendingPage.vue` | page root — the only `<.vue>` island; owns the single `<UApp>` |
| `MonthSwitcher.vue` | leaf — prev/next/this-month, pushes `select_month` |
| `MonthlySummary.vue` | leaf — per-category totals + grand total (TRM-006) |
| `SpendingList.vue` | leaf — the month's entries |
| `AddEntryModal.vue` | leaf (stateful) — `UModal` + `useLiveForm` |

`ExampleForm.vue` and `example_live.ex` are deleted; `/` is repointed at `SpendingLive`.

### Nuxt UI components — MCP-verified against `@nuxt/ui` ^4.9.0

`UApp` · `UModal` (`open` prop + `update:open` emit ⇒ `v-model:open`; `#default` is the *trigger*,
`#body`/`#footer` are scoped with `{ close }`) · `UFormField` (`:error` driven straight from server
errors — **no `UForm`**, which implies a Zod client validator the guardrails forbid) · `UInput`
(`type="text" inputmode="decimal"` for amount; `type="date"` for date) · `USelect` with
**`value-key="id" label-key="name"`** (defaults are `value`/`label`, so both are mandatory) ·
`UTextarea` · `UButton` (incl. the `form` prop so a footer button submits a `#body` form) · `UAlert`
· `UBadge` · `UCard` · `USeparator` · `UFieldGroup` (**`UButtonGroup` does not exist in v4**).

**Banned by prod SSR:** `UInputNumber`, `UInputDate`, `UCalendar` (eager `Intl.NumberFormat` /
`Intl.DateTimeFormat` at setup) and `USelectMenu` (its filter path reaches `Intl.Collator`). These
are green in dev *and* in `mix test` and crash only the production dead render — see report §0/§5.

### LiveVue integration contract

- **Props** (snake_case both sides — LiveVue does not camelize): `month`, `summary`, `entries`,
  `categories`, `form`, `form_error`, `today`, `saved_count`. Island `id="spending-page"`,
  component `"SpendingPage"`.
- **Encoder**: `@derive {LiveVue.Encoder, …}` on both resources *and* project to plain maps in the
  LiveView (the display strings have to be Elixir-formatted anyway).
- **Form**: `AshPhoenix.Form.for_create(Entry, :create, as: "form", params: %{…})` — the seeded
  `params:` are mandatory; a bare `for_create` encodes `values` as `{}`, so the date is not
  pre-filled and `String(undefined)` paints the literal text `undefined`. Always `to_vue_form/1`,
  including on the results of `validate/2` and `submit/2`.
- **Events**: `validate`, `submit`, `open_entry_form`, `select_month`.
- **Reset after save (AC1)** needs *both* halves: `{:reply, %{reset: true}, …}` (clears
  `submitCount`/`touchedFields` so the blank form does not instantly paint "required" everywhere)
  **and** the server assigning a fresh `blank_entry_form()` (this is what actually blanks the
  values — `reset()` alone copies `initialValues → currentValues` after the reply path has already
  snapshotted `initialValues := currentValues`).
- **Modal open state is client-local** (AC1 keeps the pop-up open after save), with one
  `open_entry_form` ping so the server refreshes the blank form and the category list on each open.
- **Iron Law #1**: all reads live in the `connected?(socket)` branch; the disconnected branch
  renders empty states.

### Tools the work phase uses

`nuxt-ui` MCP (`search-components` / `get-component-metadata` / `search-icons`), the `nuxt-ui` and
`vue-best-practices` skills, the LiveVue guardrails in CLAUDE.md + `deps/live_vue/usage-rules.md`,
and `deps/ash_phoenix/usage-rules/form_integration.md`.

- [ ] **F1** Delete `ExampleForm.vue` + `example_live.ex`; repoint the `/` route.
- [ ] **F2** `SpendLogWeb.SpendingLive` — `connected?`-guarded mount, prop projections, the four
      `handle_event/3` clauses.
- [ ] **F3** `SpendingPage.vue`
- [ ] **F4** `MonthSwitcher.vue`
- [ ] **F5** `MonthlySummary.vue`
- [ ] **F6** `SpendingList.vue`
- [ ] **F7** `AddEntryModal.vue`

## Tests — one per acceptance criterion

- [ ] **T1** `test/spend_log/spending/entry_test.exs` — domain-level: the five refusal rules and a
      successful create, asserting on `Ash.Error.Invalid` field messages.
- [ ] **T2** `test/spend_log_web/live/spending_live_test.exs` — `LiveVue.Test.get_vue/2` +
      `render_hook/3`, asserting on props. Covers: defaults (date = today), alphabetical category
      order, save → entry in list + summary totals + fields reset, and each refusal surfacing on the
      right field.
- [ ] **T3** `test/support/` fixtures for categories/entries.

## Verification gate

`mix precommit` (compile --warnings-as-errors, format, assets.format, credo --strict, sobelow,
deps.audit, assets.check, test) **and** `mix assets.build` (client + SSR — a component that only
breaks SSR still passes the client build).

## Risks

| Risk | Mitigation |
|---|---|
| `Intl`-dependent Nuxt UI components pass CI and crash prod SSR | Banned list above; all formatting in Elixir |
| `{reset: true}` shipped without a fresh server form → "fields keep the last entry" | Both halves implemented and asserted in T2 |
| A raw `%AshPhoenix.Form{}` reaching the encoder | `to_vue_form/1` everywhere + the repo's existing `defimpl` |
| Icons fetched from the Iconify API at runtime (no `@iconify-json/*` installed) | Never let an icon be the only carrier of meaning — always paired with `label`/`aria-label` |

## Out of scope (named so it is a decision, not an omission)

Editing/deleting entries, soft delete + recovery (TRM-007/INV-024), the category filter (TRM-008),
category management UI, and the *Uncategorized* reassignment on category delete (TRM-005). Those
belong to their own assignments; nothing here precludes them.
