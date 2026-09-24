<script setup lang="ts">
// The month's spending entries, newest first. Purely presentational.
import type { Entry, Month } from "./types"

const props = defineProps<{ entries: Entry[]; month: Month }>()
</script>

<template>
  <UCard :ui="{ body: 'p-0 sm:p-0' }">
    <template #header>
      <h2 class="text-sm font-medium text-highlighted">Entries</h2>
    </template>

    <!-- Tested before the per-month empty state, which is also true here. The two are deliberately
         different: this one says *nothing has ever been recorded*, which is the confusion a
         generic "nothing here" would cause on a user's very first visit. -->
    <UEmpty
      v-if="props.month.earliest === null"
      variant="naked"
      icon="i-lucide-wallet"
      title="No spending logged yet"
      description="Add your first entry and this page starts filling in, month by month."
      class="py-12"
      data-testid="entries-never"
    />

    <div
      v-else-if="props.entries.length === 0"
      class="flex flex-col items-center gap-2 px-4 py-12 text-center"
      data-testid="entries-empty"
    >
      <UIcon name="i-lucide-receipt-euro" class="size-8 text-dimmed" />
      <p class="text-sm text-muted">No entries for {{ props.month.label }} yet.</p>
    </div>

    <ul v-else class="divide-y divide-default">
      <li
        v-for="entry in props.entries"
        :key="entry.id"
        class="flex items-center gap-3 px-4 py-3 transition-colors duration-150 hover:bg-elevated"
      >
        <div class="min-w-0 flex-1 space-y-1">
          <div class="flex flex-wrap items-center gap-2">
            <UBadge :label="entry.category_name" color="neutral" variant="subtle" size="sm" />
            <time :datetime="entry.date" class="text-xs tabular-nums text-muted">
              {{ entry.date_display }}
            </time>
          </div>
          <p v-if="entry.note" class="truncate text-sm text-dimmed">{{ entry.note }}</p>
        </div>

        <span class="shrink-0 text-sm font-medium tabular-nums text-highlighted">
          {{ entry.amount_display }}
        </span>
      </li>
    </ul>
  </UCard>
</template>
