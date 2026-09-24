<script setup lang="ts">
// The page shell: the single Vue island for the spending screen, and the single <UApp>.
//
// This component composes and does nothing else — no form state, no fetching, no derivation. Every
// value it hands down is already final, because SpendingLive computed it. See
// `assets/vue/spending/types.ts` for why the display strings arrive pre-formatted.
import { computed, nextTick, ref } from "vue"
import { useLiveEvent } from "live_vue"
import AddEntryModal from "./spending/AddEntryModal.vue"
import MonthSwitcher from "./spending/MonthSwitcher.vue"
import MonthlySummary from "./spending/MonthlySummary.vue"
import SpendingList from "./spending/SpendingList.vue"
import type { Category, Entry, EntryFormValues, Month, Summary } from "./spending/types"
import type { Form } from "live_vue"

const props = defineProps<{
  month: Month
  summary: Summary
  entries: Entry[]
  categories: Category[]
  form: Form<EntryFormValues>
  form_error: string | null
  today: string
  saved_count: number
}>()

// Nothing has ever been recorded: there is no month worth naming and no range to move through, so
// the switcher and the summary are withheld and the list shows the first-run prompt instead.
const hasEntries = computed(() => props.month.earliest !== null)

const root = ref<HTMLElement | null>(null)

// The server owns the month, so the server says when it changed. Paging replaces the whole list,
// and without this the user lands part-way down a month they have never seen.
// `onMounted` (inside `useLiveEvent`) never runs under SSR, so there is no `window` to guard.
useLiveEvent("scroll_to_top", async () => {
  await nextTick()

  root.value?.scrollIntoView({
    block: "start",
    behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth",
  })
})
</script>

<template>
  <UApp>
    <div ref="root" class="scroll-mt-6 space-y-6">
      <header class="flex flex-wrap items-end justify-between gap-4">
        <div class="space-y-1">
          <h1 class="text-2xl font-semibold tracking-tight text-highlighted">Spending</h1>
          <p class="text-sm text-muted">Every euro, filed and totalled.</p>
        </div>

        <AddEntryModal
          :form="form"
          :categories="categories"
          :today="today"
          :form_error="form_error"
          :saved_count="saved_count"
        />
      </header>

      <template v-if="hasEntries">
        <MonthSwitcher :month="month" :today="today" />
        <MonthlySummary :summary="summary" :month="month" />
      </template>

      <SpendingList :entries="entries" :month="month" />
    </div>
  </UApp>
</template>
