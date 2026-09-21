<script setup lang="ts">
// The Monthly Summary (TRM-006): what each category cost this month, and what the month cost.
//
// Purely presentational. Every figure arrives as a finished string from the server; the only
// number here is `share`, which drives a bar width and is deliberately not money.
import type { Month, Summary } from "./types"

const props = defineProps<{ summary: Summary; month: Month }>()
</script>

<template>
  <UCard :ui="{ body: 'space-y-4' }">
    <template #header>
      <div class="flex items-baseline justify-between gap-3">
        <h2 class="text-sm font-medium text-highlighted">{{ props.month.label }}</h2>
        <p class="text-xs text-muted">
          {{ props.summary.entry_count }}
          {{ props.summary.entry_count === 1 ? "entry" : "entries" }}
        </p>
      </div>
    </template>

    <p
      v-if="props.summary.rows.length === 0"
      class="py-2 text-center text-sm text-muted"
      data-testid="summary-empty"
    >
      Nothing spent this month.
    </p>

    <ul v-else class="space-y-3">
      <li v-for="row in props.summary.rows" :key="row.category_id" class="space-y-1.5">
        <div class="flex items-baseline justify-between gap-3">
          <span class="truncate text-sm text-default">{{ row.category_name }}</span>
          <span class="text-sm font-medium tabular-nums text-highlighted">
            {{ row.total_display }}
          </span>
        </div>
        <div class="h-1.5 overflow-hidden rounded-full bg-elevated">
          <div
            class="h-full rounded-full bg-primary transition-[width] duration-500 ease-out"
            :style="{ width: `${row.share}%` }"
          />
        </div>
      </li>
    </ul>

    <template #footer>
      <div class="flex items-baseline justify-between gap-3">
        <span class="text-sm font-medium text-default">Total</span>
        <span class="text-lg font-semibold tabular-nums text-highlighted">
          {{ props.summary.total_display }}
        </span>
      </div>
    </template>
  </UCard>
</template>
