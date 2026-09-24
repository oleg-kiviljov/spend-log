# Frontend design — Browse spending entries by month

Extension of the existing single-island spending screen. **No new components.** Four files change
(`types.ts`, `MonthSwitcher.vue`, `SpendingList.vue`, `SpendingPage.vue`) plus the LiveView.

Verified against the `nuxt-ui` MCP (`search-components`, `get-component-metadata`) and
`node_modules/@nuxt/ui@4.9` sources; LiveVue APIs verified against `deps/live_vue/assets/use.ts`.

---

## a) Component breakdown — the minimal diff

| File | Role | Change |
|---|---|---|
| `assets/vue/spending/types.ts` | contract | `Month.prev` → `string \| null`; add `Month.earliest: string \| null` |
| `assets/vue/spending/MonthSwitcher.vue` | leaf | `:disabled` on the back arrow; hide the whole arrow group when `earliest === null`; `aria-live` on the label |
| `assets/vue/spending/SpendingList.vue` | leaf | add a **third** branch: `UEmpty` first-run prompt when `earliest === null` |
| `assets/vue/SpendingPage.vue` | page shell | one `useLiveEvent("scroll_to_top")` handler + a root `ref` |
| `assets/vue/spending/MonthlySummary.vue` | leaf | **unchanged** |
| `assets/vue/spending/AddEntryModal.vue` | leaf | **unchanged** |

### `types.ts`

```ts
export type Month = {
  /** "YYYY-MM" — the single value the list and the summary are both derived from. */
  value: string
  label: string
  /**
   * `null` at (or before) the month holding the earliest recorded entry, which disables the
   * control — there is nothing older to page back to.
   */
  prev: string | null
  /** `null` when the next month is in the future, which disables the control. */
  next: string | null
  /**
   * The month holding the earliest recorded entry, or `null` when no Spending Entry has ever been
   * recorded. `null` is the "nothing has ever been logged" signal the whole screen keys off: no
   * arrows at all, and the first-run prompt in place of the list.
   */
  earliest: string | null
  is_current: boolean
}
```

`mix assets.check` (`vue-tsc`) is the only compile-time check on this contract — the `types.ts`
edit must land in the same commit as the LiveView edit, or a broken prop is a silently wrong screen.

### `MonthSwitcher.vue`

```vue
<UFieldGroup v-if="props.month.earliest !== null">
  <UButton
    icon="i-lucide-chevron-left"
    color="neutral"
    variant="outline"
    square
    aria-label="Previous month"
    data-testid="month-prev"
    :disabled="props.month.prev === null"
    @click="select(props.month.prev)"
  />
  <UButton
    icon="i-lucide-chevron-right"
    color="neutral"
    variant="outline"
    square
    aria-label="Next month"
    data-testid="month-next"
    :disabled="props.month.next === null"
    @click="select(props.month.next)"
  />
</UFieldGroup>

<p
  class="text-base font-medium text-highlighted"
  aria-live="polite"
  data-testid="month-label"
>
  {{ props.month.label }}
</p>
```

- `select()` already no-ops on `null`, so a disabled arrow is inert twice over — keep that guard.
- AC4 removes the arrows from the DOM rather than disabling them: "offer NO arrow navigation at
  all". A disabled control still announces itself; an absent one does not.
- The row is `justify-between`; with the group gone the label sits left and "This month" right.
  That is fine — do **not** add a spacer element.
- Leave the "This month" button alone (`:disabled="is_current"`). With `earliest === null` the user
  is on the current month anyway, so it is already inert, and it stays as an escape hatch if a
  crafted `select_month` ever parks the session on another month.

### `SpendingList.vue`

Three mutually exclusive branches, in this order:

```vue
<template v-if="props.month.earliest !== null" #header>
  <h2 class="text-sm font-medium text-highlighted">Entries</h2>
</template>

<UEmpty
  v-if="props.month.earliest === null"
  variant="naked"
  icon="i-lucide-wallet"
  title="No spending logged yet"
  description="Add your first entry and this page starts filling in, month by month."
  class="px-4 py-12"
  data-testid="entries-empty-ever"
/>

<div
  v-else-if="props.entries.length === 0"
  class="flex flex-col items-center gap-2 px-4 py-12 text-center"
  data-testid="entries-empty"
>
  <UIcon name="i-lucide-receipt-euro" class="size-8 text-dimmed" />
  <p class="text-sm text-muted">No entries for {{ props.month.label }} yet.</p>
</div>

<ul v-else class="divide-y divide-default"> …unchanged… </ul>
```

Why the `v-if` on `#header`: `UEmpty` hard-codes its title as an `<h2>` (verified in
`node_modules/@nuxt/ui/dist/runtime/components/Empty.vue:42`). Dropping the card's own `<h2>Entries</h2>`
in the first-run state leaves exactly one heading in the card. `UCard` only renders its header
wrapper when the slot exists (`Card.vue:29`), and Vue omits a `v-if`-ed `<template #header>` from
`slots`, so this is a clean removal, not an empty bar.

---

## b) Prop contract — validated, with one improvement

The proposed `month.prev: string | null` is right. The proposed top-level `has_entries_ever:
boolean` works but is the weaker shape — **send `month.earliest: string | null` instead**:

1. **One fact, one field.** `has_entries_ever: false` alongside `prev: "2024-12"` is representable
   and wrong. With `earliest`, "nothing ever recorded" *is* `earliest === null` — the same
   single-value discipline the module already applies to `month` for INV-021.
2. **No prop threading.** `MonthSwitcher` and `SpendingList` both already receive `month`.
   A top-level boolean means editing `SpendingPage.vue`'s `defineProps` and both call sites; this
   way `SpendingPage.vue` needs no prop change at all.
3. **It fits the object's existing role.** `prev`/`next`/`is_current` are already navigation
   affordances rather than intrinsic properties of a month. `earliest` is the boundary of that
   navigation.
4. It carries strictly more information (useful later for a "jump to first month" control or an
   accurate range in copy) at the same cost.

### Server side (`SpendingLive`)

```elixir
defp month_prop(month, today, earliest) do
  next = Month.next(month)

  %{
    value: month,
    label: Month.label(month),
    # `nil` disables the control. Lexicographic compare is safe for "YYYY-MM" — the same trick
    # `Month.future?/2` relies on. `<=` not `==`: a crafted `select_month` can park the session
    # before the earliest entry, and there is still nothing older to page to.
    prev: if(is_nil(earliest) or month <= earliest, do: nil, else: Month.previous(month)),
    next: if(is_nil(earliest) or Month.future?(next, today), do: nil, else: next),
    # `nil` when no Spending Entry has ever been recorded — the switcher offers no arrows and the
    # list shows the first-run prompt.
    earliest: earliest,
    is_current: month == Month.from_date(today)
  }
end
```

Backend tasks this implies (for the Ash section of the plan):

- A `Month.t() | nil` lookup — e.g. an Ash read with `sort: [date: :asc]`, `limit: 1`,
  `select: [:date]`, exposed as a domain code interface. Index-only on the existing `[:date]`
  custom index, so it is one cheap query per `load_month/1`.
- `assign(:earliest_month, nil)` in `mount/1`; refresh it inside `load_month/1` so a save that
  creates the very first entry flips the screen out of the first-run state in the same round trip.
- **Disconnected mount shows the first-run prompt.** `earliest` is `nil` until the socket connects,
  so the SSR paint renders the placeholder and no arrows, then flips. Keep it: the module already
  documents "the first paint renders the empty states, which the Vue components handle as a
  first-class case", and faking `earliest` to today's month would put a value on screen the server
  does not know to be true. Add a line to the moduledoc saying so.

---

## c) Jump to the top of the list — server `push_event` + `useLiveEvent`

Your candidate is the correct API and the right call. Confirmed in
`deps/live_vue/assets/use.ts:35-46` — `useLiveEvent<T>(event, callback)` wraps
`live.handleEvent` in `onMounted` and `live.removeHandleEvent` in `onUnmounted`; exported from
`live_vue` (`deps/live_vue/assets/index.ts:15`).

Why server-driven rather than a client `watch` on `month.value`: only LiveView knows a month change
was actually accepted (the handler rejects unparseable and future months), and `push_event` is
assertable from ExUnit with `assert_push_event/3`. A `watch` is invisible to the test suite.

### Server

```elixir
{:noreply,
 socket
 |> assign(:month, month)
 |> load_month()
 |> push_event("scroll_to_top", %{month: month})}
```

Only in the accepted branch of `select_month`. **Not** in `submit` — saving an entry must not yank
the page, and `load_month/1` is shared by both. Including `month` in the payload costs nothing and
makes the test assertion meaningful.

### Client — `SpendingPage.vue`

```vue
<script setup lang="ts">
import { nextTick, ref } from "vue"
import { useLiveEvent } from "live_vue"

const root = ref<HTMLElement | null>(null)

// A month change swaps the list out from under the user's scroll position, so every accepted
// navigation puts the top of the page back in view. Server-driven because only LiveView knows the
// month actually changed. `useLiveEvent` registers in `onMounted`, which never runs under SSR —
// there is no `window` and no element there, and nothing here needs a guard.
useLiveEvent("scroll_to_top", async () => {
  // The props diff and the pushed event arrive together; wait for Vue to patch the new list in
  // before moving the viewport.
  await nextTick()
  root.value?.scrollIntoView({
    block: "start",
    behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth",
  })
})
</script>

<template>
  <UApp>
    <div ref="root" class="space-y-6">
```

Decisions inside that snippet:

- **Scroll the island root, not the window and not the list card.** `<Layouts.app>` is
  `<main class="px-4 py-8">` with no sticky chrome (`layouts.ex:37`), so aligning the island root to
  the viewport top *is* the top of the page — and it keeps the arrows on screen, which
  `listCard.scrollIntoView()` would not (the switcher sits above the list). `scrollIntoView` also
  survives the layout ever gaining an internal scroll container, which `window.scrollTo({top: 0})`
  would not. The list is not itself a scroll container, so there is no `scrollTop` to reset.
- **SSR:** nothing extra to do. `onMounted` does not run during `renderToString`, and template refs
  are `null` there. **Do not** set `v-ssr={false}` on this island — the screen must still
  server-render.
- **Reduced motion:** `smooth` on a long list is the delightful version; honour
  `prefers-reduced-motion` rather than forcing it.
- Let Prettier format this (`semi: false`, `printWidth: 100`, `arrowParens: "avoid"`).

---

## d) The first-run placeholder — `UEmpty`

**Verified via MCP `get-component-metadata Empty`** → `UEmpty` / `u-empty`, category `data`,
props `icon`, `avatar`, `title`, `description`, `actions: ButtonProps[]`, `variant:
"outline" | "solid" | "soft" | "subtle" | "naked"` (default `outline`), `size`, `loading`, `ui`;
slots `header`, `leading`, `title`, `description`, `body`, `actions`, `footer`; no emits.
Present in the installed tree at `node_modules/@nuxt/ui/dist/runtime/components/Empty.vue`
(`@nuxt/ui ^4.9.0`), and listed in the skill's offline fallback
(`.claude/skills/nuxt-ui/references/components.md:40`).

- **`UEmpty` over `UAlert`**: `UAlert` is for a message *about* a state (error, warning, notice);
  this is the zero state of a data region, which is exactly what `UEmpty` names.
- **`UEmpty` over the hand-rolled `UCard` + `UIcon` pattern**: that pattern stays for the per-month
  empty (see (e)) — it is a one-line aside. The first-run state is the whole screen's welcome and
  earns the component with the icon/title/description structure already built.
- **`variant="naked"`** because it renders inside the existing `UCard`; the default `outline` would
  draw a second border. `class="px-4 py-12"` matches the existing empty block's rhythm.
- `icon="i-lucide-wallet"` (verified via MCP `search-icons`) — deliberately different from the
  per-month `i-lucide-receipt-euro`, so the two states do not look like the same thing.
- **No `actions`.** A working "Add your first entry" button would have to drive `AddEntryModal`'s
  internal `open` ref, which means lifting that state into `SpendingPage` (`v-model:open` + emit).
  Mounting a second `AddEntryModal` is not an option — two `useLiveForm` instances on one form prop
  would double every change event. Out of scope here; note it as a clearly-bounded follow-up if a
  clickable CTA is wanted.

### Copy (resolving the `[NEEDS CLARIFICATION]`)

> **No spending logged yet**
> Add your first entry and this page starts filling in, month by month.

Chosen because it: (1) says *nothing has ever been recorded*, not *nothing here* — so the user does
not go hunting for the right month, which is the single confusion this state has to prevent;
(2) names no month, because none is meaningful yet; (3) is forward-looking rather than a dead end,
and explains the month-by-month model the arrows will later expose; (4) points at the "Add entry"
action without hard-coding button chrome into prose; (5) is short and plain, matching the voice
already on the page ("Every euro, filed and totalled.", "Nothing spent this month.").

---

## e) Two empty states, both must stay correct

| | condition | UI |
|---|---|---|
| **Never recorded** | `month.earliest === null` | `UEmpty` first-run prompt, no card header, **no arrows at all** (group removed from the DOM), "This month" governed by `is_current` as today |
| **Empty month** | `month.earliest !== null && entries.length === 0` | Existing `UIcon` + "No entries for {{ month.label }} yet." block, **both arrows present**, each enabled/disabled per `prev`/`next` |
| **Populated** | `entries.length > 0` | Unchanged list |

The order of the branches matters: `earliest === null` must be tested **first**, because
`entries.length === 0` is true in both empty cases and cannot distinguish them.

`MonthlySummary` is untouched in both: it keeps showing "Nothing spent this month." and a €0.00
total. Considered hiding the summary card in the never-recorded state and rejected — a zeroed
summary shows a first-run user the shape of what they are about to get, and hiding it would mean an
extra `v-if` in `SpendingPage.vue` for no correctness gain.

AC1's "sorted most recent first" is already satisfied server-side —
`Entry.list_for_month` builds `sort: [date: :desc, inserted_at: :desc]`
(`lib/spend_log/spending/entry.ex:84`). No frontend sorting; never sort in Vue.

---

## f) Accessibility and testability

**Accessibility**

- Keep `aria-label="Previous month"` / `"Next month"` on the icon-only arrows.
- Use native **`:disabled`**, not `aria-disabled`. `UButton` forwards `disabled` to the rendered
  `<button>` (`Button.vue:121`) and styles it `disabled:opacity-75 disabled:cursor-not-allowed`.
  That matches what the next arrow already does, and there is no reason to keep an inert control
  focusable here — the month label beside it fully explains the state.
- **Add `aria-live="polite"` to the month label.** Paging months keeps focus on the arrow button
  while the entire page content changes underneath; without the live region a screen reader user
  gets no announcement at all. This is the one real a11y gap in the current screen.
- AC4's arrows are removed from the DOM rather than disabled, so there is nothing left to label.
- `UEmpty`'s `<h2>` replaces the card's `<h2>Entries</h2>` in the first-run state (see (a)), so the
  heading outline stays one-per-region.

**Testability** — tests assert on props via `LiveVue.Test.get_vue/2`, not markup
(`test/spend_log_web/live/spending_live_test.exs:1-20`; `enable_props_diff: false` in
`config/test.exs`). The `data-testid` hooks below are for a future browser-level suite only; every
acceptance criterion must be provable from props or pushed events:

| AC | Assertion |
|---|---|
| 1 | `props(view)["month"]["value"]` / `["label"]`; entry ids/dates in `props(view)["entries"]` in `date: :desc` order |
| 1 (scroll) | `assert_push_event(view, "scroll_to_top", %{month: "2025-01"})` after `render_hook(view, "select_month", …)`; and `refute_push_event` after a `submit` |
| 2 | `props(view)["month"]["next"] == nil` on the current month |
| 3 | `props(view)["month"]["prev"] == nil` when the selected month holds the earliest entry; non-nil one month later |
| 4 | `props(view)["month"]["earliest"] == nil` on an empty database, with `prev == nil` **and** `next == nil` |

Stable hooks to add: `data-testid="month-prev"`, `data-testid="month-next"`,
`data-testid="month-label"`, `data-testid="entries-empty-ever"`; **keep** the existing
`data-testid="entries-empty"` on the per-month block so the two states remain distinguishable.

---

## Tools the work phase needs

- **`nuxt-ui` MCP** — `get-component-metadata Empty` before writing the placeholder; `Button` for
  the `disabled` prop; `search-icons` for any icon not listed here.
- **`nuxt-ui` skill** — load before touching any `U*` usage; `references/components.md` is the
  offline fallback if the MCP is down.
- **`vue-best-practices` skill** — load before editing any `.vue` file.
- **LiveVue guardrails** (`CLAUDE.md`) + `deps/live_vue/usage-rules.md` — server owns state, no
  client fetching, `useLiveEvent` for server→client.
- **Verification**: `mix assets.check` (vue-tsc — the only check that sees the prop contract),
  `mix assets.build` (client + SSR), `mix precommit`. Do not hand-format `.vue`/`.ts`; Prettier owns
  them via `mix assets.format`.
