<script setup lang="ts">
// The add-entry pop-up.
//
// The only stateful component on the page, and it owns exactly one piece of state: whether the
// dialog is open. Everything else — values, errors, validity — lives in LiveView and arrives via
// the `form` prop.
//
// Three details that are easy to get wrong and hard to notice:
//
//   1. `useLiveForm` is created here in setup, NOT inside the `#body` slot. UModal unmounts its
//      content on close, so a composable created in the slot would be torn down mid-flight and
//      `form.submit()` would be unreachable from the footer.
//   2. There is no <UForm> and no client-side schema. Validation is the server's, always; each
//      UFormField's `error` is just whatever LiveView said about that field.
//   3. Nothing here formats a number or a date. The inputs are plain text/date controls, and the
//      amount stays a string end to end so it can reach Ash's decimal cast intact.
import { computed, ref, watch } from "vue"
import { useLiveForm, useLiveVue, type Form } from "live_vue"
import type { Category, EntryFormValues } from "./types"

const props = defineProps<{
  form: Form<EntryFormValues>
  categories: Category[]
  today: string
  form_error: string | null
  saved_count: number
}>()

const live = useLiveVue()

const form = useLiveForm(() => props.form, {
  changeEvent: "validate",
  submitEvent: "submit",
  debounceInMiliseconds: 300,
  // An empty string is not a UUID, so sending it would get "is invalid" where the user needs
  // "please select a category". nil is the honest representation of "nothing chosen".
  prepareData: data => ({ ...data, category_id: data.category_id || null }),
})

const amountField = form.field("amount")
const dateField = form.field("date")
const categoryField = form.field("category_id")
const noteField = form.field("note")

const open = ref(false)
const submitting = ref(false)
const justSaved = ref(false)
let savedTimer: ReturnType<typeof setTimeout> | undefined

function onOpenChange(value: boolean) {
  open.value = value
  // Ask the server for a fresh form on every open: the date stays right across a midnight
  // rollover, errors from an abandoned attempt are dropped, and the category list is current.
  if (value) live.pushEvent("open_entry_form", {})
}

// The pop-up stays open after a save, so the only signal that anything happened is this. Driven by
// the server's counter rather than a local flag, so it cannot get out of step with what was saved.
watch(
  () => props.saved_count,
  (count, previous) => {
    if (count > (previous ?? 0)) {
      justSaved.value = true
      clearTimeout(savedTimer)
      savedTimer = setTimeout(() => (justSaved.value = false), 2000)
    }
  },
)

// Errors show once the user has touched a field, and unconditionally after a failed submit —
// `isTouched` already folds in `submitCount > 0`.
const amountError = computed(() =>
  amountField.isTouched.value ? amountField.errorMessage.value : undefined,
)
const dateError = computed(() =>
  dateField.isTouched.value ? dateField.errorMessage.value : undefined,
)
const categoryError = computed(() =>
  categoryField.isTouched.value ? categoryField.errorMessage.value : undefined,
)

async function onSubmit() {
  submitting.value = true
  try {
    await form.submit()
  } finally {
    submitting.value = false
  }
}
</script>

<template>
  <UModal
    :open="open"
    title="Add a spending entry"
    description="The pop-up stays open after saving, so you can log another straight away."
    :ui="{ footer: 'justify-end gap-2' }"
    @update:open="onOpenChange"
  >
    <UButton label="Add entry" icon="i-lucide-plus" color="primary" />

    <template #body>
      <form id="add-entry-form" class="space-y-4" @submit.prevent="onSubmit">
        <UAlert
          v-if="props.form_error"
          color="error"
          variant="subtle"
          icon="i-lucide-circle-alert"
          :description="props.form_error"
        />

        <UFormField label="Amount" hint="EUR" name="amount" required :error="amountError">
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

        <UFormField label="Date" name="date" required :error="dateError">
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

        <UFormField label="Category" name="category_id" required :error="categoryError">
          <USelect
            :model-value="categoryField.value.value || undefined"
            :items="props.categories"
            value-key="id"
            label-key="name"
            :name="categoryField.inputAttrs.value.name"
            placeholder="Choose a category"
            icon="i-lucide-tag"
            leading
            class="w-full"
            @update:model-value="categoryField.value.value = String($event ?? '')"
            @blur="categoryField.inputAttrs.value.onBlur()"
          />
        </UFormField>

        <UFormField label="Note" hint="Optional" name="note">
          <UTextarea
            :model-value="String(noteField.value.value ?? '')"
            :name="noteField.inputAttrs.value.name"
            :rows="2"
            :maxrows="5"
            autoresize
            placeholder="What was it for?"
            class="w-full"
            @update:model-value="noteField.value.value = String($event ?? '')"
          />
        </UFormField>
      </form>
    </template>

    <template #footer="{ close }">
      <Transition
        enter-active-class="transition duration-200 ease-out"
        enter-from-class="opacity-0 translate-y-1"
        leave-active-class="transition duration-150 ease-in"
        leave-to-class="opacity-0"
      >
        <UBadge
          v-if="justSaved"
          label="Saved"
          icon="i-lucide-check"
          color="success"
          variant="subtle"
          size="sm"
          class="mr-auto"
        />
      </Transition>

      <UButton label="Done" color="neutral" variant="outline" @click="close" />
      <UButton
        type="submit"
        form="add-entry-form"
        label="Save entry"
        color="primary"
        :loading="submitting"
        :disabled="submitting"
      />
    </template>
  </UModal>
</template>
