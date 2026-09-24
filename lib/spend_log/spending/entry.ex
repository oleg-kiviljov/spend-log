defmodule SpendLog.Spending.Entry do
  @moduledoc """
  A single record of money spent (TRM-003): an amount in EUR, a date, a category, and an optional
  note.

  Two invariants are enforced here rather than in the UI, because the UI is not the only way in:

    * INV-023 — the amount is a `Decimal` (never a float, Iron Law #4) stored to two decimal places
      and held inside €1.00 .. €1,000,000.00 inclusive.
    * INV-019 — every entry belongs to exactly one category. `category_id` is non-nullable at the
      attribute *and* the database level.

  An entry may only be logged for today or a past date; see `Validations.DateNotFuture`.
  """
  use Ash.Resource,
    domain: SpendLog.Spending,
    data_layer: AshPostgres.DataLayer

  alias SpendLog.Spending.Entry.Preparations.FilterByMonth
  alias SpendLog.Spending.Entry.Validations.CategoryExists
  alias SpendLog.Spending.Entry.Validations.DateNotFuture

  # `:category` is deliberately absent — an unloaded belongs_to encodes as %Ash.NotLoaded{} and
  # raises in LiveVue's encoder. The LiveView projects `category.name` explicitly instead.
  @derive {LiveVue.Encoder, only: [:id, :amount, :date, :note, :category_id]}

  @min_amount Decimal.new("1.00")
  @max_amount Decimal.new("1000000.00")

  @doc "The smallest amount an entry may record (INV-023)."
  @spec min_amount() :: Decimal.t()
  def min_amount, do: @min_amount

  @doc "The largest amount an entry may record (INV-023)."
  @spec max_amount() :: Decimal.t()
  def max_amount, do: @max_amount

  postgres do
    table "spending_entries"
    repo SpendLog.Repo

    custom_indexes do
      # Every read of this table filters on a month's date range, so without this the spending
      # list and the Monthly Summary both degrade into a sequential scan as entries accumulate.
      index [:date]
    end
  end

  code_interface do
    domain SpendLog.Spending
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:amount, :date, :note, :category_id]

      # The bounds are two separate validations rather than one range check so each can name the
      # limit the user actually hit. The literal "€1.00"/"€1,000,000.00" is in the message on
      # purpose: LiveVue's translate_errors/1 only interpolates %{} placeholders when the matching
      # opts are supplied, and no gettext backend is configured for live_vue.
      validate compare(:amount, greater_than_or_equal_to: @min_amount) do
        message "the minimum allowed amount is €1.00"
      end

      validate compare(:amount, less_than_or_equal_to: @max_amount) do
        message "the maximum allowed amount is €1,000,000.00"
      end

      validate DateNotFuture
      validate present(:category_id), message: "please select a category"
      validate CategoryExists
    end

    read :list_for_month do
      argument :year, :integer, allow_nil?: false
      argument :month, :integer, allow_nil?: false

      prepare FilterByMonth
      # JOINed with the entries (Iron Law #6 — JOIN for belongs_to), so rendering the list and
      # folding the Monthly Summary never issues a query per row.
      prepare build(sort: [date: :desc, inserted_at: :desc], load: [:category])
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :amount, :decimal do
      allow_nil? false
      public? true
      # scale: 2 is the "formatted to two decimal places" half of INV-023; the min/max halves are
      # the action validations above, which can name the bound they enforce.
      constraints precision: 12, scale: 2
    end

    attribute :date, :date, allow_nil?: false, public?: true

    attribute :note, :string do
      public? true
      constraints trim?: true, max_length: 500
    end

    timestamps()
  end

  relationships do
    belongs_to :category, SpendLog.Spending.Category do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end
end
