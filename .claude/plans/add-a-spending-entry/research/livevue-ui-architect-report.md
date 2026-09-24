# Frontend design — "Add a spending entry"

Agent: `livevue-ui-architect`. Stack verified against this repo, not from memory.

**Verified environment facts** (all re-checked in-tree, do not re-derive):

| Fact | Source |
|---|---|
| `@nuxt/ui` **^4.9.0**, `vue-tsc` 3, `vite` 8, Tailwind 4 (Vite plugin) | `/workspace/app/package.json` |
| Nuxt UI Vite plugin runs `ui({ router: false, colorMode: false })` | `/workspace/app/assets/vite.config.mjs:52` |
| `assets/vue/index.ts` registers the Nuxt UI plugin per island and renders `h(component, props, { ...slots })` | `/workspace/app/assets/vue/index.ts:34-37` |
| `to_vue_form/1` + `defimpl LiveVue.Encoder, for: AshPhoenix.Form` already exist (permanent infra) | `/workspace/app/lib/spend_log_web/live_vue_helpers.ex` |
| `config :live_vue, enable_props_diff: false` already set for tests | `/workspace/app/config/test.exs:6` |
| Test env sets **no** `:ssr_module` → `LiveVue.SSR.render/3` returns `%{preloadLinks: "", html: ""}`, so **SSR never executes under `mix test`** | `/workspace/app/deps/live_vue/lib/live_vue/ssr.ex:38-41` |
| Prod SSR = `LiveVue.SSR.QuickBEAM` (QuickJS in BEAM). Its only `Intl` implementation is **`Intl.Segmenter` (grapheme)** | `deps/quickbeam/README.md:357`, `deps/quickbeam/lib/quickbeam/js.ex:106,177` |
| `/` currently routes to `ExampleLive`; `ExampleLive` + `ExampleForm.vue` are to be deleted | `lib/spend_log_web/router.ex:23` |

---

## 0. The one constraint that drives every component choice: **no `Intl` in prod SSR**

`LiveVue.SSR.QuickBEAM` boots QuickJS with `apis: [:browser, :node]`
(`lib/spend_log/ssr_runtime.ex:31`). QuickBEAM's `:intl` API group loads **only** the
`unicode-segmenter` adapter — `Intl.Segmenter`. `Intl.NumberFormat`, `Intl.DateTimeFormat` and
`Intl.Collator` are **absent**.

Any Nuxt UI component whose `setup()` constructs one of those will throw `TypeError` during the
**dead render in prod only** — `mix test` will not catch it (no `ssr_module` in test) and
`mix phx.server` will not catch it (dev uses `LiveVue.SSR.ViteJS` → real Node → full `Intl`).
This is exactly the failure class `to_vue_form/1` was written for.

Confirmed eager (constructor-time, not lazy) `Intl` construction:

- `reka-ui/dist/NumberField/NumberFieldRoot.js:130` calls `useNumberFormatter(locale, formatOptions)`
  at setup → `@internationalized/number` `NumberFormatter` constructor →
  `new Intl.NumberFormat(...)` (`node_modules/@internationalized/number/dist/private/NumberFormatter.mjs:42`).
  ⇒ **`UInputNumber` is banned.**
- `UInputDate` / `UCalendar` depend on `@internationalized/date` (`DateFormatter`, `toCalendar`) →
  `Intl.DateTimeFormat`. ⇒ **`UInputDate` and `UCalendar` are banned.**
- `reka-ui/dist/shared/useFilter.js:21` builds its `Intl.Collator` inside a `computed`, so it is lazy
  — but it is reached by `USelectMenu`'s filtering path. ⇒ **`USelectMenu` is avoided** for this
  feature (we use `USelect`, which has no filter path at all).

**Therefore all money and date formatting for display is done in Elixir and pushed down as
pre-formatted strings.** That is also the correct LiveVue posture (server owns state) and keeps the
`:decimal` Iron Law intact end-to-end — no JS float ever touches an amount.

---

## 1. Component breakdown

All files are new, all in `assets/vue/`, all `<script setup lang="ts">`, all PascalCase.
**Delete `assets/vue/ExampleForm.vue` and `lib/spend_log_web/live/example_live.ex`** as part of this
work and repoint `live "/", SpendingLive` in `lib/spend_log_web/router.ex:23`.

| File | Role | Notes |
|---|---|---|
| `assets/vue/SpendingPage.vue` | **page root / the only `<.vue>` island** | Owns `<UApp>`. Composes the four leaves. No `useLiveForm` here. |
| `assets/vue/MonthSwitcher.vue` | leaf | prev / label / next + "This month". Pushes `select_month`. |
| `assets/vue/MonthlySummary.vue` | leaf | per-category rows + grand total. Pure display. |
| `assets/vue/SpendingList.vue` | leaf | the month's entries. Pure display. |
| `assets/vue/AddEntryModal.vue` | leaf (stateful) | `UModal` + trigger button + **`useLiveForm`**. |

Single island, single `UApp`, no `v-inject` — this feature is one page, not a persistent layout, so
the `v-inject` id/`{ ...slots }` guardrail does not apply here (the `{ ...slots }` spread in
`index.ts` stays as-is regardless).

### `SpendingPage.vue`

```ts
defineProps<{
  month: MonthProp
  summary: SummaryProp
  entries: EntryProp[]
  categories: CategoryProp[]
  form: Form<EntryFormValues>   // from "live_vue"
  form_error: string | null
  today: string                 // "YYYY-MM-DD"
  saved_count: number
}>()
```

No emits — children talk to the server directly via `useLiveVue()`. Props are **snake_case on both
sides**: LiveVue performs **no camelization** (verified — no `camelize` anywhere in `deps/live_vue`),
so the HEEx attribute name is the literal Vue prop name and the literal `get_vue` props key.

Types (declare in each SFC, or a shared `assets/vue/types.ts`):

```ts
type CategoryProp = { id: string; name: string }
type EntryProp = {
  id: string
  date: string            // ISO, for sorting/keying
  date_display: string    // "21 Sep 2026" — formatted in Elixir
  amount_display: string  // "€12.34" — formatted in Elixir
  note: string | null
  category_id: string
  category_name: string
}
type SummaryRow = { category_id: string; category_name: string; total_display: string; share: number }
type SummaryProp = { rows: SummaryRow[]; total_display: string; entry_count: number }
type MonthProp = {
  value: string        // "2026-09"
  label: string        // "September 2026" — formatted in Elixir
  prev: string
  next: string | null  // null when the next month is in the future
  is_current: boolean
}
type EntryFormValues = { amount: string; date: string; category_id: string; note: string }
```

### `MonthSwitcher.vue`
- props: `month: MonthProp`
- emits: none. Calls `useLiveVue().pushEvent("select_month", { month })`.

### `MonthlySummary.vue`
- props: `summary: SummaryProp`, `month: MonthProp`
- emits: none.

### `SpendingList.vue`
- props: `entries: EntryProp[]`, `month: MonthProp`
- emits: none. `v-for … :key="entry.id"`.

### `AddEntryModal.vue`
- props: `form: Form<EntryFormValues>`, `categories: CategoryProp[]`, `today: string`,
  `form_error: string | null`, `saved_count: number`
- emits: none. Owns `const open = ref(false)` (client-local, see §3.5).

---

## 2. Nuxt UI components — exact names and props (verified via `nuxt-ui` MCP against v4)

Every prop/slot below was read from `get-component-metadata` in this session. Semantic color tokens
only (`text-default`, `text-muted`, `text-dimmed`, `text-highlighted`, `bg-elevated`, `bg-muted`,
`border-default`, `divide-default`) — **never** `gray-500`/`slate-*`/`red-600`.

### Overlay — `UModal` ✔

Decision matrix (`references/guidelines/component-selection.md:9`): *focused task / form* → `UModal`,
not `USlideover`. Declarative `v-model:open`, not `useOverlay()` (LiveVue override: the server must be
able to see and re-render inside the overlay).

Verified: prop **`open`** (`"The controlled open state of the dialog. Can be binded as v-model:open"`)
+ emit **`update:open`** ⇒ **`v-model:open` is correct.** Other verified props used here:
`title`, `description`, `close` (`boolean | ButtonProps`), `dismissible` (default `true`),
`unmountOnHide` (default `true`), `ui` (`{ overlay, content, header, wrapper, body, footer, title, description, close }`).
Verified slots: `default` (= the **trigger**), `content`, `header`, `title`, `description`, `actions`,
`close`, `body`, `footer` — `content` / `header` / `body` / `footer` are scoped with `{ close: () => void }`.

```vue
<UModal
  :open="open"
  title="Add a spending entry"
  description="Log what you spent. The pop-up stays open so you can add another."
  :ui="{ footer: 'justify-end gap-2' }"
  @update:open="onOpenChange"
>
  <UButton label="Add entry" icon="i-lucide-plus" color="primary" />
  <template #body> … fields … </template>
  <template #footer="{ close }"> … buttons … </template>
</UModal>
```

`@update:open` (not bare `v-model`) so we can push `open_entry_form` to the server on open — see §3.5.

### Form wrapper — `UFormField` ✔

Verified props: `label`, `description`, `help`, `hint`, `error` (`string | boolean | undefined`),
`required`, `size`, `name`, `errorPattern`, `orientation`, `eagerValidation`, `validateOnInputDelay`, `ui`.
Verified slots: `label`, `hint`, `description`, `help`, `error`, `default` (scoped `{ error }`).

**Do not use `UForm`.** LiveVue override — `UForm` implies a Standard-Schema (Zod/Valibot) client
validator, which is exactly what the guardrails forbid. We use a plain `<form @submit.prevent>` and
drive `UFormField`'s **`error` prop directly** from `useLiveForm`'s server errors. `UFormField`'s
`name` prop only matters for `UForm` error matching, so it is optional here — pass it anyway for a11y
consistency, and **do not pass `id` to the child input**: let `UFormField` own label/`for` wiring
(this is the pattern `ExampleForm.vue:53-65` already proves works in this template).

### Amount — `UInput` (`type="text"`), **not `UInputNumber`** ✔

Three independent reasons: (1) `UInputNumber` crashes prod SSR (§0); (2) it emits a JS `number` —
a float — for money, which collides with Iron Law #4 the moment anyone rounds it; (3) its
`formatOptions` locale parsing would mangle `1,000.00` vs `1.000,00`.

Verified `UInput` props used: `type` (union explicitly includes `"text"` **and `"date"`**),
`modelValue`, `name`, `placeholder`, `icon`/`leadingIcon`/`leading`, `trailing`, `color`, `highlight`,
`size`, `max`, `min`, `step`, `required`, `disabled`, `autocomplete`, `ui`
(`{ root, base, leading, leadingIcon, … }`). Verified slots: `leading`, `default`, `trailing`.
Verified emits: `update:modelValue`, `blur`, `change`.

```vue
<UFormField
  label="Amount"
  required
  name="amount"
  hint="EUR"
  :error="amountField.isTouched.value ? amountField.errorMessage.value : undefined"
>
  <UInput
    :model-value="String(amountField.value.value ?? '')"
    :name="amountField.inputAttrs.value.name"
    type="text"
    inputmode="decimal"
    autocomplete="off"
    placeholder="0.00"
    icon="i-lucide-euro"
    leading
    class="w-full"
    :ui="{ base: 'tabular-nums' }"
    @update:model-value="amountField.value.value = String($event ?? '')"
    @blur="amountField.inputAttrs.value.onBlur()"
  />
</UFormField>
```

`inputmode="decimal"` is a plain passthrough attr (not a declared prop) — correct, it lands on the
inner `<input>` via fallthrough. The value stays a **string** all the way to `Ash.Type.Decimal`.

### Date — `UInput type="date"`, **not `UInputDate`** ✔

`type="date"` is in `UInput`'s verified `type` union. The native control gives `"YYYY-MM-DD"`, which
`Ash.Type.Date` casts directly, needs zero `Intl`, and is SSR-inert. `:max="today"` is a courtesy
client hint for AC4 — **the server still rejects future dates** (never trust the client).

```vue
<UFormField
  label="Date"
  required
  name="date"
  :error="dateField.isTouched.value ? dateField.errorMessage.value : undefined"
>
  <UInput
    :model-value="String(dateField.value.value ?? props.today)"
    :name="dateField.inputAttrs.value.name"
    type="date"
    :max="props.today"
    class="w-full"
    @update:model-value="dateField.value.value = String($event ?? '')"
    @blur="dateField.inputAttrs.value.onBlur()"
  />
</UFormField>
```

### Category — `USelect`, **not `USelectMenu`** ✔

`references/guidelines/component-selection.md:44` — *small fixed list (< 10 items)* → `USelect`.
Plus `USelect` has no `useFilter`/`Intl.Collator` path at all (§0). Categories arrive
**already sorted alphabetically by the server** — do **not** sort in Vue (server owns state, and a
JS `.sort()` without `Intl.Collator` would be byte-order, not locale-order).

Verified `USelect` props (v4 names, exact): **`items`**, **`valueKey`** (default `'value'` —
*"select the field to use as the value"*), **`labelKey`** (default `'label'`), `descriptionKey`,
`modelValue`, `placeholder`, `name`, `required`, `disabled`, `icon`, `color`, `highlight`,
`nullableValue`, `portal` (default `true`), `content`, `ui`. Verified emits: `update:modelValue`,
`update:open`, `change`, `blur`, `focus`. Verified slots include `item`, `item-label`, `item-leading`.

Because our items are `{ id, name }`, **both keys must be overridden**: `value-key="id"`
`label-key="name"`.

```vue
<UFormField
  label="Category"
  required
  name="category_id"
  :error="categoryField.isTouched.value ? categoryField.errorMessage.value : undefined"
>
  <USelect
    :model-value="categoryField.value.value || undefined"
    :items="props.categories"
    value-key="id"
    label-key="name"
    :name="categoryField.inputAttrs.value.name"
    placeholder="Choose a category"
    icon="i-lucide-tag"
    class="w-full"
    @update:model-value="categoryField.value.value = ($event as string) ?? ''"
    @blur="categoryField.inputAttrs.value.onBlur()"
  />
</UFormField>
```

`|| undefined` (not `?? undefined`) so the blank `""` default renders the **placeholder** rather than
an empty selected item — this is what satisfies "category blank" in the AC1 reset.

### Note — `UTextarea` ✔

Verified props: `modelValue`, `name`, `rows` (default `3`), `maxrows`, `autoresize`,
`autoresizeDelay`, `placeholder`, `maxlength`, `color`, `highlight`, `ui`. Emits `update:modelValue`,
`blur`, `change`.

```vue
<UFormField label="Note" name="note" hint="Optional"
            :error="noteField.isTouched.value ? noteField.errorMessage.value : undefined">
  <UTextarea
    :model-value="String(noteField.value.value ?? '')"
    :name="noteField.inputAttrs.value.name"
    :rows="2" :maxrows="5" autoresize
    placeholder="What was it for?"
    class="w-full"
    @update:model-value="noteField.value.value = String($event ?? '')"
    @blur="noteField.inputAttrs.value.onBlur()"
  />
</UFormField>
```

### Buttons — `UButton` ✔

Verified props: `label`, `icon`/`leadingIcon`/`trailingIcon`, `color`, `variant`
(`solid|outline|soft|subtle|ghost|link`), `size`, `block`, `square`, `loading`, `loadingAuto`,
`disabled`, `type` (`"button"|"submit"|"reset"`, default `"button"`), **`form`** (string — lets a
footer button submit a `<form>` living in `#body`).

- Trigger (modal `#default` slot): `<UButton label="Add entry" icon="i-lucide-plus" color="primary" />`
- Footer submit: `<UButton type="submit" form="add-entry-form" label="Save entry" icon="i-lucide-check" :loading="submitting" :disabled="submitting" />`
- Footer close: `<UButton label="Done" color="neutral" variant="outline" @click="close" />`
- Month nav: `<UButton icon="i-lucide-chevron-left" color="neutral" variant="ghost" square aria-label="Previous month" />`

### Form-level error — `UAlert` ✔

Verified props: `title`, `description`, `icon`, `color`, `variant` (`solid|outline|soft|subtle`),
`orientation`, `actions` (`ButtonProps[]`), `close`, `ui`. Emits `update:open`.

`<UAlert v-if="form_error" color="error" variant="subtle" icon="i-lucide-circle-alert" :description="form_error" />`
inside `#body`, above the fields. **Not** `useToast()` — Nuxt UI override says toasts → LiveView
flash for server-driven messages, and `component-selection.md:84` forbids toasts for information the
user must act on (AC5 is exactly that).

### Category chip — `UBadge` ✔

Verified props: `label`, `color`, `variant` (`solid|outline|soft|subtle`), `size`, `icon`,
`leadingIcon`, `square`, `as` (default `'span'`), `ui`.
`<UBadge :label="entry.category_name" color="neutral" variant="subtle" size="sm" />`

### Containers — `UCard` ✔ / `UFieldGroup` ✔ / `USeparator` ✔

- `UCard` verified props: `title`, `description`, `variant` (`solid|outline|soft|subtle`), `as`,
  `ui` (`{ root, header, title, description, body, footer }`); slots `header`, `title`,
  `description`, `default`, `footer`. Two cards: Monthly Summary, Spending list.
- **`UButtonGroup` does not exist in v4 — it is `UFieldGroup`** (MCP: `get-component-metadata
  ButtonGroup` → `404`; `search-components "button group"` → `field-group`). Verified `UFieldGroup`
  props: `as`, `size`, `orientation` (`horizontal|vertical`), `ui: { base }`. Use it to bind the
  prev/next month buttons together.
- `USeparator` for the summary's total rule.

### Table — deliberately **not** `UTable`

`@tanstack/vue-table` **is** installed (`node_modules/@tanstack/vue-table/package.json`), so `UTable`
would work. We skip it: a TanStack column model + `h()` cell renderers is a lot of client machinery
and SSR weight for a read-only list the server already formats, and CLAUDE.md asks for hand-written
Tailwind for a distinctive look. Build the list as a semantic `<ul>` of rows inside `UCard`:
date (`text-muted text-sm tabular-nums`) · `UBadge` category · note (`text-dimmed truncate`) ·
amount right-aligned `tabular-nums font-medium text-highlighted`. Empty state: a centered
`UIcon name="i-lucide-receipt-euro"` + "No entries for {month.label} yet."

### Icons — `UIcon` / the `icon` props

Verified present in lucide via `search-icons`: `i-lucide-euro`, `i-lucide-receipt-euro`,
`i-lucide-chevron-left`. Also used (verify each with `search-icons` before writing):
`i-lucide-chevron-right`, `i-lucide-plus`, `i-lucide-check`, `i-lucide-tag`, `i-lucide-circle-alert`,
`i-lucide-calendar`. **No `hero-*`, no HEEx `<.icon>`** — heroicons is removed from this project.

### `UApp` ✔

Verified props: `tooltip`, `toaster`, `locale`, `portal` (default `'body'`), `dir`, `scrollBody`, `nonce`.
Exactly **one** `<UApp>`, as the outermost element of `SpendingPage.vue` — `UModal` portals to `body`
and needs `UApp`'s provider context. Do **not** add a second `UApp` inside `AddEntryModal.vue`.
Do not use `UColorModeButton`/`useColorMode` — `colorMode: false` in `vite.config.mjs`.

---

## 3. LiveVue integration contract

### 3.1 Host LiveView

`lib/spend_log_web/live/spending_live.ex`, routed at `live "/", SpendingLive`.

```heex
<Layouts.app flash={@flash}>
  <.vue
    v-component="SpendingPage"
    id="spending-page"
    month={@month}
    summary={@summary}
    entries={@entries}
    categories={@categories}
    form={@form}
    form_error={@form_error}
    today={@today}
    saved_count={@saved_count}
  />
</Layouts.app>
```

- `<Layouts.app flash={@flash}>` is mandatory (Phoenix 1.8 rule) and is where flashes render —
  `Layouts.app` already emits `<.flash_group>` (`lib/spend_log_web/components/layouts.ex:43`).
- `id="spending-page"` is the handle for `LiveVue.Test.get_vue(view, id: "spending-page")`.
- `~H` here is `LiveVue.SharedPropsView.sigil_H` (swapped in `spend_log_web.ex`) — it injects
  `v-socket` automatically. Do not pass `v-socket` by hand.
- **Iron Law #1**: all reads (`categories`, `entries`, `summary`) go in the `connected?(socket)`
  branch of `mount/3` (or `assign_async`); the disconnected branch assigns empty
  `categories: []`, `entries: []`, `summary: %{rows: [], total_display: "€0.00", entry_count: 0}`.
  The Vue components must render correctly against those empty defaults (they will — the empty
  states are part of the design).

### 3.2 `LiveVue.Encoder` — required derivations

Every struct crossing the prop boundary needs an encoder, or SSR/prop-diff raises
`Protocol.UndefinedError`. **Do not pass raw Ash structs.** Two layers of protection, do both:

1. **Derive on the resources** (belt):
   ```elixir
   # lib/spend_log/spending/category.ex
   @derive {LiveVue.Encoder, only: [:id, :name]}

   # lib/spend_log/spending/entry.ex
   @derive {LiveVue.Encoder, only: [:id, :amount, :date, :note, :category_id]}
   ```
   Never include the `:category` relationship in `only:` — an unloaded `belongs_to` encodes as
   `%Ash.NotLoaded{}` and blows up (`deps/live_vue/lib/live_vue/encoder.ex:144` documents the Ecto
   twin of this trap).

2. **Project to plain maps in the LiveView** (braces) — this is the pattern to actually ship, because
   the display strings must be formatted in Elixir anyway (§0):
   ```elixir
   defp to_entry_prop(entry) do
     %{
       id: entry.id,
       date: Date.to_iso8601(entry.date),
       date_display: format_date(entry.date),          # "21 Sep 2026"
       amount_display: format_eur(entry.amount),       # "€12.34" — Decimal → string, no floats
       note: entry.note,
       category_id: entry.category_id,
       category_name: entry.category.name              # requires load: [:category]
     }
   end
   ```
   `format_eur/1` must operate on `Decimal` (`Decimal.round(d, 2) |> Decimal.to_string(:normal)`),
   never `Float`. Put both formatters in a plain module in the domain folder
   (`lib/spend_log/spending/money.ex` + `spending.ex` root module) per the placement rule, or as
   private helpers on the LiveView if they are used nowhere else.

3. **`form`** — `%Phoenix.HTML.Form{}` already has an encoder
   (`deps/live_vue/lib/live_vue/encoder.ex:123`), and this repo additionally implements
   `LiveVue.Encoder` for raw `%AshPhoenix.Form{}` (`live_vue_helpers.ex:57`). Still always store the
   **normalized** form: `assign(socket, :form, to_vue_form(form))`.

### 3.3 The encoded form prop — exact shape (this drives the whole Vue form)

`encode/2` produces `%{name:, values:, errors:, valid:}` (`encoder.ex:124-133`).

For an `AshPhoenix.Form` the **fallback** `encode_form_values/2` runs (encoder.ex:249-259):
`form.hidden |> Map.new() |> Map.merge(form.data) |> Map.merge(Map.new(form.params))`.

⚠ **Consequence:** a bare `AshPhoenix.Form.for_create/3` has `params: %{}` and `data: nil`, so
`values` encodes as **`{}`** — every `field.value.value` is `undefined`, the date is not pre-filled,
and `String(undefined)` renders `"undefined"` in the input.

**Fix (mandatory, and it is also how AC1's defaults are delivered):** seed the params.

```elixir
defp blank_entry_form do
  today = Date.utc_today()

  SpendLog.Spending.Entry
  |> AshPhoenix.Form.for_create(:create,
       domain: SpendLog.Spending,
       as: "form",
       params: %{
         "amount" => "",
         "date" => Date.to_iso8601(today),
         "category_id" => "",
         "note" => ""
       }
     )
  |> to_vue_form()
end
```

`as: "form"` ⇒ the encoded `name` is `"form"` ⇒ `useLiveForm` pushes `%{"form" => params}`
(`deps/live_vue/assets/useLiveForm.ts:288,540` — the payload key is literally `initialForm.name`)
⇒ handlers match `handle_event("validate", %{"form" => params}, socket)`. String keys in `params`,
matching `Map.new(form.params)` in the encoder.

`errors` encodes as `translate_errors(form.errors)` → `%{field_atom => [msg, …]}` → JSON
`{"amount": ["…"]}`. `valid` reads `form.source.valid?` — `%AshPhoenix.Form{}` has `valid?`, so it
works.

### 3.4 `useLiveForm()` wiring — `AddEntryModal.vue`

```ts
import { useLiveForm, useLiveVue, type Form } from "live_vue"

const props = defineProps<{
  form: Form<EntryFormValues>
  categories: CategoryProp[]
  today: string
  form_error: string | null
  saved_count: number
}>()

const live = useLiveVue()

const form = useLiveForm(() => props.form, {
  changeEvent: "validate",
  submitEvent: "submit",
  debounceInMiliseconds: 300,
  // "" is not a valid UUID cast — send nil so Ash reports "required", not "is invalid"
  prepareData: data => ({ ...data, category_id: data.category_id || null }),
})

const amountField = form.field("amount")
const dateField = form.field("date")
const categoryField = form.field("category_id")
const noteField = form.field("note")

const submitting = ref(false)
async function onSubmit() {
  submitting.value = true
  try { await form.submit() } finally { submitting.value = false }
}
```

- `changeEvent: "validate"` ⇒ every field mutation schedules a 300 ms-debounced
  `pushEvent("validate", {form: …})`. This is what makes AC2/AC3/AC4 messages appear *as the user
  types*, from the server, with zero client validation logic.
- `field.value` is a **writable computed**; assigning `field.value.value = x` mutates state and fires
  the debounce (`useLiveForm.ts:324-327`).
- `field.errorMessage.value` = first server error; `field.isTouched.value` =
  `submitCount > 0 || touchedFields.has(path)` (`useLiveForm.ts:341`) — so gating `UFormField`'s
  `:error` on `isTouched` shows nothing before interaction and **everything after a failed submit**.
  Wire `@blur="field.inputAttrs.value.onBlur()"` on each input so per-field touch works before submit
  (`inputAttrs.onBlur` is `setTouched`, `useLiveForm.ts:355`).
- `useLiveForm` is created in the **always-mounted** `AddEntryModal.vue` setup, not inside the
  `#body` slot (which `UModal` unmounts on close, `unmountOnHide: true`). This keeps `form.submit()`
  callable from the `#footer` slot.

### 3.5 Modal open/close state — **client-local**, with one server ping

AC1 says the pop-up **stays open** and its fields reset so the user can log another. So there is no
server-driven close, and per the guardrails ("component-internal client state (open/closed …) is
fine") the open flag lives in Vue:

```ts
const open = ref(false)
function onOpenChange(value: boolean) {
  open.value = value
  if (value) live.pushEvent("open_entry_form", {})
}
```

`open_entry_form` makes the server rebuild `blank_entry_form()` and re-read `categories` on every
open — that guarantees today's date is fresh across a midnight rollover, clears any stale errors from
a previous abandoned attempt, and keeps the category list current (which also softens AC5).
Server-owned open state would be wrong here: it would round-trip a purely visual toggle and make the
dialog flicker on every unrelated re-render.

### 3.6 Event contract

**Vue → server** (`useLiveVue().pushEvent` / `useLiveForm`):

| Event | Payload | Emitted by | Server |
|---|---|---|---|
| `"validate"` | `%{"form" => params}` | `useLiveForm` changeEvent (debounced 300 ms) | `AshPhoenix.Form.validate/2` → `assign(:form, to_vue_form(form))` |
| `"submit"` | `%{"form" => params}` | `useLiveForm` submitEvent | `AshPhoenix.Form.submit/2`, **must `{:reply, …}`** (§3.7) |
| `"open_entry_form"` | `%{}` | `AddEntryModal` `@update:open(true)` | rebuild blank form + refresh categories |
| `"select_month"` | `%{"month" => "2026-08"}` | `MonthSwitcher` | reload entries + summary, refuse future months |

**Server → Vue:** none. No `useLiveEvent()` is needed — all feedback arrives as prop changes plus
LiveView flash rendered by `Layouts.app`. **Navigation:** none (single page). If a link is ever
added, it must be LiveVue's `<Link navigate=… />` / `useLiveNavigation()` — never vue-router
(`router: false` is set on the Vite plugin anyway).

**Iron Law #8** — every one of these four `handle_event/3` clauses authorizes. Even with no auth
scope today, run the Ash action with an `actor:` (and never `authorize?: false`), and validate
`"month"` against a strict `~r/^\d{4}-\d{2}$/` + `Date.from_iso8601/1` before use. **No
`String.to_atom/1` on anything in these payloads** (Iron Law #7).

### 3.7 "Reset after save" — the exact mechanism (both halves are required)

Read `deps/live_vue/assets/useLiveForm.ts:531-561`. `form.submit()` pushes the event **with a reply
callback**, and:

```js
live.pushEvent(submitEvent, { [initialForm.name]: data }, result => {
  if (result && result.reset) {
    setTimeout(() => { Object.assign(initialValues, deepClone(currentValues)); reset() }, 0)
  }
})
```

Note what `reset()` does (`:525-529`): it copies **`initialValues` → `currentValues`**, clears
`touchedFields`, and zeroes `submitCount`. Because the reply path first snapshots
`initialValues := currentValues`, **`{reset: true}` alone does NOT blank the inputs.** What blanks
them is the *server* assigning a fresh `blank_entry_form()`, which flows down as a new `form` prop and
is applied by the prop watcher (`:519-523` → `updateFromServer` → `Object.assign(currentValues,
newForm.values)`, `:512-514`). Both timeouts are `setTimeout(…, 0)`; LiveView applies the diff before
invoking the reply callback, so the watcher's timeout is queued first and the blank values win.

So implement **both**:

```elixir
def handle_event("submit", %{"form" => params}, socket) do
  case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
    {:ok, _entry} ->
      {:reply, %{reset: true},
       socket
       |> assign(:form, blank_entry_form())          # ← blanks the values
       |> assign(:form_error, nil)
       |> assign(:saved_count, socket.assigns.saved_count + 1)
       |> reload_month()}                            # entries + summary for @month

    {:error, form} ->
      {:reply, %{reset: false},
       socket
       |> assign(:form, to_vue_form(form))           # ← re-wrap EVERY time
       |> assign(:form_error, form_level_error(form))
       |> assign(:categories, list_categories())}    # AC5: drop the vanished category
  end
end
```

- `socket.assigns.form.source` is the `%AshPhoenix.Form{}` inside the normalized
  `%Phoenix.HTML.Form{}` (the documented pattern in `live_vue_helpers.ex:24-26`).
- `to_vue_form/1` on **every** assignment of the form — `validate/2` and `submit/2` both return a bare
  `%AshPhoenix.Form{}`.
- `{reset: true}` is what clears `submitCount`/`touchedFields`, so the freshly blank form does not
  immediately paint "required" errors under every field. Without it the reset is visually wrong.
- `reload_month/1` must re-read entries **and** summary so AC1's "appears in the list / counts in the
  totals" holds. If the saved entry's date falls **outside** the selected month, keep the selected
  month as-is and set a flash (`put_flash(:info, "Saved to <Month> — switch months to see it.")`);
  do not silently hide the entry.

### 3.8 Error surfacing per field (AC2–AC6)

`useLiveForm` reads `props.form.errors` keyed by field name, so **every user-visible rule must be a
field error on the right field**. Backend contract this frontend depends on:

| AC | Field | Message that must reach `errors.<field>[0]` |
|---|---|---|
| 2 | `amount` | `"minimum allowed amount is €1.00"` |
| 3 | `amount` | the max message, e.g. `"maximum allowed amount is €1,000,000.00"` |
| 4 | `date` | e.g. `"cannot be in the future"` |
| 5 | `category_id` | `"the selected category no longer exists — please choose another"` |
| 6 | `category_id` | `"please select a category"` |

Two notes for the implementer:

- `translate_errors/1` interpolates `%{key}` from the error `opts`
  (`encoder.ex:321-332`) unless `:live_vue, :gettext_backend` is configured (it is not). So put the
  literal `€1.00` / `€1,000,000.00` in the message string and **avoid `%{…}` placeholders** unless the
  matching `opts` are supplied.
- **AC5 must be a `category_id` field error, not a bare form-level error.** AshPhoenix errors with no
  field do not land on a usable key (the encoder would produce a `null` key). Shape the backend so
  a stale/unknown `category_id` produces an `Ash.Error.Changes.InvalidAttribute`/`InvalidRelationship`
  with `field: :category_id`. The `form_error` prop + `UAlert` is the **safety net** for anything that
  still arrives field-less (`form_level_error/1` extracts those); it is not the primary path.

### 3.9 `entries` as a plain list vs a stream

Prescribed: plain encoded list prop. One user's entries for one month is a bounded set, far under the
Iron Law's >100 floor, and a plain prop keeps `get_vue(...).props["entries"]` directly assertable.

Escape hatch, verified available if the list can realistically grow past a couple hundred rows:
LiveVue **does** accept `%Phoenix.LiveView.LiveStream{}` props — `entries={@streams.entries}` is
detected (`deps/live_vue/lib/live_vue.ex:96`), serialized to `data-streams-diff`, and patched into the
reactive props client-side (`deps/live_vue/assets/hooks.ts:19,61`). Switching later is a one-line
change on the LiveView side; the Vue component still sees an array.

---

## 4. How the tests assert this

`config :live_vue, enable_props_diff: false` is already in `config/test.exs:6`, so
`LiveVue.Test.get_vue/2` sees **full** props on every render. SSR does not run in test
(`ssr_module` unset), so these tests will **not** catch the `Intl` class of bug — see §5.

New file: `test/spend_log_web/live/spending_live_test.exs`.

**Component name to query:** `"SpendingPage"`. **Island id:** `"spending-page"`.

```elixir
{:ok, view, _html} = live(conn, ~p"/")
vue = LiveVue.Test.get_vue(view, id: "spending-page")   # or name: "SpendingPage"
assert vue.component == "SpendingPage"
```

**Prop keys to assert on** (all string keys, snake_case — LiveVue does not camelize):
`"form"`, `"categories"`, `"entries"`, `"summary"`, `"month"`, `"today"`, `"form_error"`,
`"saved_count"`.

The `"form"` prop is the encoded map with keys `"name"`, `"values"`, `"errors"`, `"valid"`.

Interactions use `render_hook/3` with the **same payload shape `useLiveForm` sends** —
`%{"form" => %{...}}`, all four fields present, `category_id` as `nil` when blank (because of
`prepareData`):

```elixir
defp params(overrides \\ %{}) do
  Map.merge(
    %{"amount" => "12.34", "date" => Date.to_iso8601(Date.utc_today()),
      "category_id" => nil, "note" => ""},
    overrides
  )
end
```

| AC | Test |
|---|---|
| defaults | `props["form"]["values"]["date"] == Date.to_iso8601(Date.utc_today())`; `values["amount"] == ""`; `values["category_id"] == ""`; `values["note"] == ""` |
| categories sorted | `Enum.map(props["categories"], & &1["name"]) == Enum.sort(names)` — seed out of order (e.g. `["Travel", "食", "Groceries"]`) so the assertion can actually fail |
| 1 (save) | `render_hook(view, "submit", %{"form" => params(%{"category_id" => cat.id})})`; then re-`get_vue`: `props["entries"]` gains an item whose `"amount_display"` is `"€12.34"`; `props["summary"]["total_display"]` reflects it; `props["saved_count"] == 1` |
| 1 (reset) | after the same submit: `props["form"]["values"] == %{"amount" => "", "date" => today_iso, "category_id" => "", "note" => ""}` and `props["form"]["errors"] == %{}` |
| 2 | `render_hook(view, "submit", %{"form" => params(%{"amount" => "0.50", "category_id" => cat.id})})` → `props["form"]["errors"]["amount"] == ["minimum allowed amount is €1.00"]`; `props["form"]["valid"] == false`; `props["entries"] == []` |
| 3 | same with `"amount" => "1000000.01"` → `errors["amount"]` matches the max message |
| 4 | `"date" => Date.utc_today() \|> Date.add(1) \|> Date.to_iso8601()` → `errors["date"] != nil`, `props["entries"] == []` |
| 5 | seed a category, `Ash.destroy!` it, then submit with its id → `errors["category_id"]` mentions "no longer exists"; and `props["categories"]` no longer contains that id |
| 6 | `"category_id" => nil` → `errors["category_id"]` prompts to select one |
| validate round-trip | `render_hook(view, "validate", %{"form" => params(%{"amount" => "0.50"})})` → `errors["amount"]` present **and** `props["entries"]` unchanged (validation must not write) |
| month switch | `render_hook(view, "select_month", %{"month" => "2026-08"})` → `props["month"]["value"] == "2026-08"`, entries scoped to that month |
| month guard | `render_hook(view, "select_month", %{"month" => "not-a-month"})` → no crash, `props["month"]` unchanged |
| open resets | `render_hook(view, "open_entry_form", %{})` after a failed submit → `props["form"]["errors"] == %{}` |

Assert on **prop values**, not on rendered HTML: the Vue island renders to a `data-props` attribute
in dead render, so `has_element?` against Nuxt UI internals is meaningless here. Keep `id=` /
`name=` on the island stable — the tests key off them.

---

## 5. Pitfalls — read before writing a line

1. **`Intl` is absent in prod SSR (QuickBEAM) but present in dev (ViteJS/Node) and never exercised in
   test.** Consequence: `UInputNumber`, `UInputDate`, `UCalendar` (and the `USelectMenu` filter path)
   are **green locally and in CI, and crash the dead render in production**. This is why §2 picks
   `UInput type="text"` / `UInput type="date"` / `USelect`. If a future need forces one of them, gate
   it with `v-ssr={false}` on the island (verified attr, `deps/live_vue/lib/live_vue.ex:32,97`) and
   accept the blank first paint. Add an entry to the plan's risk list.
2. **Format money and dates in Elixir, never in Vue.** No `toLocaleString`, no `Intl.NumberFormat`,
   no `new Date(...).toLocaleDateString()` anywhere in these SFCs. QuickJS's non-`Intl`
   `toLocaleString` silently falls back to `toString()` — you get `12.34` in prod and `€12.34`
   in dev, which is worse than a crash. Pair with Iron Law #4: no JS float ever holds an amount.
3. **The empty-`values` trap.** A bare `AshPhoenix.Form.for_create/3` encodes `values` as `{}`
   (§3.3). Always seed `params:`. Symptom if you forget: the date input is blank instead of today, and
   `String(undefined)` paints the literal text `undefined` in the amount box.
4. **`to_vue_form/1` on every form assignment**, including the results of `validate/2` and `submit/2`.
   The `data: nil` → `Map.merge(_, nil)` `BadMapError` is a prod-SSR crash
   (`live_vue_helpers.ex:9-34`). The repo's `LiveVue.Encoder` impl for `AshPhoenix.Form` is a net, not
   a licence to skip it.
5. **`{reset: true}` does not clear values by itself** — the fresh server form does (§3.7). Shipping
   only one of the two halves produces the classic "fields keep the last entry but the errors
   disappear" bug, which reads as a successful reset in a quick manual test and fails AC1.
6. **`UModal` unmounts its content on close** (`unmountOnHide: true`). Keep `useLiveForm` in
   `AddEntryModal.vue`'s setup, not inside `#body`, or `form.submit()` is unreachable from `#footer`
   and every open re-instantiates the composable mid-flight.
7. **One `UApp`, outermost in `SpendingPage.vue`.** Modal/tooltip providers come from it, and it must
   not be nested — `assets/vue/index.ts:37` already registers the Nuxt UI plugin per island, so the
   plugin is present; `UApp` supplies the *runtime* context. Never touch `useColorMode`/
   `UColorModeButton` (`colorMode: false`).
8. **`UButtonGroup` does not exist in v4 — use `UFieldGroup`.** (MCP `get-component-metadata
   ButtonGroup` returns 404.) Same class of rename trap: verify every `U*` against the MCP before
   typing it.
9. **`USelect` key defaults are `value`/`label`.** Our items are `{ id, name }`, so
   `value-key="id" label-key="name"` are **not optional**. Forgetting them yields a select whose
   options all render blank and whose model value is the whole object.
10. **Prop names are passed through verbatim** — no camelization in LiveVue. `form_error` in HEEx is
    `form_error` in `defineProps` and `props["form_error"]` in the test. Mixing cases produces a
    silently `undefined` prop.
11. **Prettier owns `.vue`/`.ts`.** Do not hand-format. `mix precommit` runs `assets.format` in write
    mode; `.prettierrc.json` sets `semi: false`, `printWidth: 100`, `arrowParens: "avoid"`.
12. **Icons resolve over the network.** No `@iconify-json/*` package is installed
    (`node_modules/@iconify-json/` does not exist), so `i-lucide-*` icons are fetched from the
    Iconify API at runtime and render as empty placeholders during SSR. `ExampleForm.vue` already
    relies on this, so it is the status quo — but never let an icon be the *only* carrier of meaning
    (always pair with `label` / `aria-label`). Optional improvement to raise with the user: add
    `@iconify-json/lucide` as a devDependency for offline/deterministic icons.
13. **Verification is two commands, not one.** `mix assets.build` must pass (it runs **both** the
    client and the SSR build) in addition to `mix precommit`. A component that only breaks SSR
    compiles fine in the client build.

---

## 6. Tools `/phx:work` must use for these tasks

- **`nuxt-ui` MCP** — `search-components` / `get-component-metadata` / `get-example` /
  `search-icons` before writing any `U*` tag or icon name. Offline fallback:
  `.claude/skills/nuxt-ui/references/components.md`. Never guess.
- **`nuxt-ui` skill** (`.claude/skills/nuxt-ui/SKILL.md`) — MANDATORY load before touching any `U*`.
  Relevant references: `guidelines/component-selection.md` (overlay + input matrices),
  `guidelines/forms.md` (field layout, modal-form footer pattern — but **ignore its `UForm`/Zod
  sections**, superseded by the LiveVue override), `guidelines/design-system.md` (semantic colors),
  `recipes/overlays.md`.
- **`vue-best-practices` skill** — MANDATORY load before touching any `.vue`.
- **LiveVue guardrails** — `CLAUDE.md` §"LiveVue guardrails" + `deps/live_vue/usage-rules.md`; source
  of truth for `useLiveForm`, testing, and encoder rules. They win over both skills on conflict.
- **`ash_phoenix` usage rules** — `deps/ash_phoenix/usage-rules/form_integration.md` (`for_create`
  with `params:`) and `error_handling.md`.

## 7. Task list for `/phx:work` (frontend only)

1. Delete `assets/vue/ExampleForm.vue` and `lib/spend_log_web/live/example_live.ex`; repoint
   `live "/", SpendingLive` in `lib/spend_log_web/router.ex`.
2. Add `@derive {LiveVue.Encoder, only: […]}` to `Category` and `Entry` (§3.2).
3. Write `SpendLogWeb.SpendingLive`: `connected?`-guarded mount, `blank_entry_form/0` with seeded
   `params:`, prop projections with Elixir-side `€`/date formatting, and the four `handle_event/3`
   clauses — `submit` returning `{:reply, %{reset: true}, …}` (§3.7).
4. `assets/vue/SpendingPage.vue` — `UApp`, page shell, composition, snake_case props.
5. `assets/vue/MonthSwitcher.vue` — `UFieldGroup` + two ghost square `UButton`s + `select_month`.
6. `assets/vue/MonthlySummary.vue` — `UCard` + rows + `USeparator` + total.
7. `assets/vue/SpendingList.vue` — `UCard` + `<ul>` rows + `UBadge` + empty state.
8. `assets/vue/AddEntryModal.vue` — `UModal` (`:open`/`@update:open`), `useLiveForm`, the four
   `UFormField` blocks from §2, `UAlert` for `form_error`, footer `UButton`s.
9. `test/spend_log_web/live/spending_live_test.exs` — the table in §4.
10. Run `mix assets.build` **and** `mix precommit`.

### Micro-interactions to include (CLAUDE.md UI/UX mandate)
`transition-colors duration-150` on list rows with `hover:bg-elevated`; `:loading="submitting"` on the
save button; `tabular-nums` on every amount so columns align; a transient "Saved" `UBadge`
(`color="success" variant="subtle"`) in the modal header driven by watching `saved_count`, auto-hidden
after ~2 s; `UButton` `disabled` on the next-month control when `month.next === null`;
`aria-label` on every icon-only button.
