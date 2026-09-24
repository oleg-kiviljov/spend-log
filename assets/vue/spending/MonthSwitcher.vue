<script setup lang="ts">
// Picks the month the rest of the page is about.
//
// It holds no state of its own: it renders `month` and asks the server to change it. That is what
// keeps the summary and the list on the same month (INV-021) — there is only ever one month, and
// the server owns it.
import { computed } from "vue"
import { useLiveVue } from "live_vue"
import type { Month } from "./types"

const props = defineProps<{
  month: Month
  /** Today as "YYYY-MM-DD"; its first seven characters are the current month. */
  today: string
}>()

const live = useLiveVue()

const currentMonth = computed(() => props.today.slice(0, 7))

function select(month: string | null) {
  if (month) live.pushEvent("select_month", { month })
}
</script>

<template>
  <div class="flex items-center justify-between gap-3">
    <UFieldGroup>
      <UButton
        icon="i-lucide-chevron-left"
        color="neutral"
        variant="outline"
        square
        aria-label="Previous month"
        :disabled="props.month.prev === null"
        @click="select(props.month.prev)"
      />
      <UButton
        icon="i-lucide-chevron-right"
        color="neutral"
        variant="outline"
        square
        aria-label="Next month"
        :disabled="props.month.next === null"
        @click="select(props.month.next)"
      />
    </UFieldGroup>

    <!-- Paging changes the entire page while focus stays on the arrow, so the month has to be
         announced or a screen-reader user gets no feedback at all. -->
    <p class="text-base font-medium text-highlighted" aria-live="polite">
      {{ props.month.label }}
    </p>

    <UButton
      label="This month"
      color="neutral"
      variant="ghost"
      size="sm"
      :disabled="props.month.is_current"
      @click="select(currentMonth)"
    />
  </div>
</template>
