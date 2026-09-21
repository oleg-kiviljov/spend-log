defmodule SpendLog.Spending.Entry.Validations.DateNotFuture do
  @moduledoc """
  Refuses a Spending Entry dated after today — spending can only be *logged*, not predicted.

  Why a custom module and not the built-in `compare/2`: `compare/2` takes a comparand fixed when the
  resource compiles, and "today" is not. This validation only runs on `:create`, so it needs no
  `atomic/3` callback despite `default_actions_require_atomic?: true` (that flag governs updates and
  destroys).
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :date) do
      # A missing date is already the `allow_nil?: false` attribute's error to report; adding a
      # second one here would just double up under the same field.
      nil ->
        :ok

      date ->
        if Date.after?(date, Date.utc_today()) do
          {:error,
           field: :date,
           message: "cannot be in the future — log spending for today or a past date"}
        else
          :ok
        end
    end
  end

  @impl true
  def describe(_opts), do: [message: "must not be in the future", vars: []]
end
