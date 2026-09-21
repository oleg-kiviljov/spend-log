defmodule SpendLog.SpendingFixtures do
  @moduledoc """
  Test data for the spending domain, built through the domain's own code interfaces.

  Going through the real actions (rather than `Ash.Seed`) keeps fixtures honest: if a validation
  changes such that this data is no longer creatable, the fixtures fail loudly instead of seeding
  rows the application itself would refuse to produce.
  """
  alias SpendLog.Spending

  @doc """
  Creates a category. Names are suffixed with a unique integer unless one is given, so async tests
  do not collide on the `spending_categories_unique_name_index` (INV-022).
  """
  def category_fixture(attrs \\ %{}) do
    name = attrs[:name] || "Category #{System.unique_integer([:positive])}"
    Spending.create_category!(name)
  end

  @doc "Creates a spending entry, defaulting to €10.00 spent today in a fresh category."
  def entry_fixture(attrs \\ %{}) do
    {category, attrs} = Map.pop_lazy(Map.new(attrs), :category, &category_fixture/0)

    %{
      amount: Decimal.new("10.00"),
      date: Date.utc_today(),
      note: nil,
      category_id: category.id
    }
    |> Map.merge(attrs)
    |> Spending.create_entry!()
  end

  @doc """
  Creates the four default categories (TRM-004) in a deliberately non-alphabetical order, so a test
  asserting on alphabetical ordering can actually fail.
  """
  def default_categories_fixture do
    Enum.map(~w(Transport Food Entertainment Rent), &category_fixture(name: &1))
  end
end
