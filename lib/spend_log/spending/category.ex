defmodule SpendLog.Spending.Category do
  @moduledoc """
  A label a Spending Entry is filed under (TRM-004).

  The default set is Food, Transport, Rent and Entertainment, seeded by `priv/repo/seeds.exs`.
  Names are globally unique (INV-022), enforced by the `:unique_name` identity and the unique index
  AshPostgres generates from it.
  """
  use Ash.Resource,
    domain: SpendLog.Spending,
    data_layer: AshPostgres.DataLayer,
    # The primary read sorts alphabetically. Ash warns because a primary read is also what
    # relationship loads and policy checks go through — which is exactly the point: there is no
    # context in this app where an unordered list of categories is the right answer.
    primary_read_warning?: false

  # Only the two fields the client ever needs. Never derive a relationship: an unloaded
  # `belongs_to`/`has_many` encodes as %Ash.NotLoaded{} and raises in LiveVue's encoder.
  @derive {LiveVue.Encoder, only: [:id, :name]}

  postgres do
    table "spending_categories"
    repo SpendLog.Repo
  end

  code_interface do
    domain SpendLog.Spending
  end

  actions do
    defaults [:destroy]

    read :read do
      primary? true
      # Alphabetical by default, so every list of categories the user sees — the picker and the
      # Monthly Summary alike — is already in the order the assignment asks for.
      prepare build(sort: [name: :asc])
    end

    create :create do
      primary? true
      accept [:name]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints trim?: true, allow_empty?: false, min_length: 1, max_length: 60
    end

    timestamps()
  end

  identities do
    identity :unique_name, [:name] do
      message "a category with this name already exists"
    end
  end
end
