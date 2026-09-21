<script setup lang="ts">
// The page shell: the single Vue island for the spending screen, and the single <UApp>.
//
// This component composes and does nothing else — no form state, no fetching, no derivation. Every
// value it hands down is already final, because SpendingLive computed it. See
// `assets/vue/spending/types.ts` for why the display strings arrive pre-formatted.
import AddEntryModal from "./spending/AddEntryModal.vue"
import MonthSwitcher from "./spending/MonthSwitcher.vue"
import MonthlySummary from "./spending/MonthlySummary.vue"
import SpendingList from "./spending/SpendingList.vue"
import type { Category, Entry, EntryFormValues, Month, Summary } from "./spending/types"
import type { Form } from "live_vue"

defineProps<{
  month: Month
  summary: Summary
  entries: Entry[]
  categories: Category[]
  form: Form<EntryFormValues>
  form_error: string | null
  today: string
  saved_count: number
}>()
</script>

<template>
  <UApp>
    <div class="space-y-6">
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

      <MonthSwitcher :month="month" :today="today" />
      <MonthlySummary :summary="summary" :month="month" />
      <SpendingList :entries="entries" :month="month" />
    </div>
  </UApp>
</template>
