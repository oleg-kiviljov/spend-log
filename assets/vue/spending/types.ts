// Shape of every prop the SpendingLive LiveView pushes down.
//
// Two conventions that are load-bearing here:
//
//   * Names are snake_case, matching the HEEx attributes verbatim — LiveVue does not camelize.
//   * Anything ending in `_display` is already formatted by the server. Never reformat it, and
//     never do arithmetic on it: production SSR has no `Intl`, and money must never touch a JS
//     float. The raw `date` field is ISO and is there for keys and sorting only.

export type Category = {
  id: string
  name: string
}

export type Entry = {
  id: string
  date: string
  date_display: string
  amount_display: string
  note: string | null
  category_id: string
  category_name: string
}

export type SummaryRow = {
  category_id: string
  category_name: string
  total_display: string
  /** 0–100, this category's share of the month. Computed server-side. */
  share: number
}

export type Summary = {
  rows: SummaryRow[]
  total_display: string
  entry_count: number
}

export type Month = {
  /** "YYYY-MM" — the single value the list and the summary are both derived from. */
  value: string
  label: string
  /**
   * The month holding the earliest entry ever recorded, or `null` when nothing has ever been
   * recorded. `null` is the first-run signal: the page shows a placeholder prompt instead of a
   * list, and offers no month navigation at all.
   */
  earliest: string | null
  /** `null` at the earliest recorded month, which disables the back arrow. */
  prev: string | null
  /** `null` when the next month is in the future, which disables the forward arrow. */
  next: string | null
  is_current: boolean
}

export type EntryFormValues = {
  amount: string
  date: string
  category_id: string
  note: string
}
