defmodule SpendLog.Spending.Entry.Validations.CategoryExists do
  @moduledoc """
  Refuses an entry whose category has been removed since the form was rendered, and says so on the
  `category_id` field.

  The foreign key is what *guarantees* INV-019 — this validation does not replace it, and the
  window between this check and the INSERT stays closed by the constraint. What the FK cannot do is
  talk: a constraint violation arrives without a field, so LiveVue's encoder would file it under a
  `null` key and the user would be told nothing actionable. This runs first and puts a message the
  user can act on next to the picker they need to act on.
  """
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :category_id) do
      # Absence is `present(:category_id)`'s error to report, not ours.
      nil ->
        :ok

      category_id ->
        if Ash.exists?(Ash.Query.filter(SpendLog.Spending.Category, id == ^category_id)) do
          :ok
        else
          {:error,
           field: :category_id,
           message: "the selected category no longer exists — please choose another"}
        end
    end
  end

  @impl true
  def describe(_opts), do: [message: "must refer to a category that still exists", vars: []]
end
