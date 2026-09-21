defmodule SpendLog.Spending.EntryTest do
  @moduledoc """
  Domain-level cover for the Spending Entry rules.

  These sit underneath the LiveView tests on purpose: the invariants (INV-019, INV-023, "today or
  earlier") belong to the resource, not to one screen, and must hold for any caller.
  """
  use SpendLog.DataCase, async: true

  import SpendLog.SpendingFixtures

  alias SpendLog.Spending

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{amount: Decimal.new("12.34"), date: Date.utc_today(), category_id: category_fixture().id},
      Map.new(overrides)
    )
  end

  # An anchor month that is wholly in the past whenever the suite runs, so these tests never depend
  # on where in the calendar "today" happens to fall.
  defp past_month, do: Date.utc_today() |> Date.beginning_of_month() |> Date.shift(month: -1)
  defp past_month_day(day), do: Date.new!(past_month().year, past_month().month, day)

  # Collects every message Ash reported against `field`.
  defp errors_for(%Ash.Error.Invalid{errors: errors}, field) do
    errors
    |> Enum.filter(&(Map.get(&1, :field) == field or field in Map.get(&1, :fields, [])))
    |> Enum.map(&to_string(Map.get(&1, :message, "")))
  end

  describe "create" do
    test "saves an entry with an amount, date, category and note" do
      category = category_fixture(name: "Food")

      assert {:ok, entry} =
               Spending.create_entry(
                 valid_attrs(%{
                   amount: Decimal.new("12.34"),
                   date: past_month_day(1),
                   note: "Lunch",
                   category_id: category.id
                 })
               )

      assert Decimal.equal?(entry.amount, Decimal.new("12.34"))
      assert entry.date == past_month_day(1)
      assert entry.note == "Lunch"
      assert entry.category_id == category.id
    end

    test "accepts the inclusive bounds €1.00 and €1,000,000.00" do
      assert {:ok, _} = Spending.create_entry(valid_attrs(%{amount: Decimal.new("1.00")}))
      assert {:ok, _} = Spending.create_entry(valid_attrs(%{amount: Decimal.new("1000000.00")}))
    end

    test "the note is optional" do
      assert {:ok, entry} = Spending.create_entry(valid_attrs())
      assert entry.note == nil
    end

    test "refuses an amount below €1.00, naming the minimum" do
      assert {:error, error} = Spending.create_entry(valid_attrs(%{amount: Decimal.new("0.99")}))
      assert "the minimum allowed amount is €1.00" in errors_for(error, :amount)
    end

    test "refuses an amount above €1,000,000.00, naming the maximum" do
      assert {:error, error} =
               Spending.create_entry(valid_attrs(%{amount: Decimal.new("1000000.01")}))

      assert "the maximum allowed amount is €1,000,000.00" in errors_for(error, :amount)
    end

    test "refuses a date beyond today" do
      tomorrow = Date.add(Date.utc_today(), 1)

      assert {:error, error} = Spending.create_entry(valid_attrs(%{date: tomorrow}))
      assert Enum.any?(errors_for(error, :date), &(&1 =~ "cannot be in the future"))
    end

    test "accepts today and past dates" do
      assert {:ok, _} = Spending.create_entry(valid_attrs(%{date: Date.utc_today()}))
      assert {:ok, _} = Spending.create_entry(valid_attrs(%{date: ~D[2020-01-01]}))
    end

    test "refuses an entry with no category, prompting the user to select one" do
      attrs = valid_attrs() |> Map.delete(:category_id)

      assert {:error, error} = Spending.create_entry(attrs)
      assert "please select a category" in errors_for(error, :category_id)
    end

    test "refuses a category that is no longer present, telling the user to choose again" do
      category = category_fixture()
      Spending.delete_category!(category)

      assert {:error, error} = Spending.create_entry(valid_attrs(%{category_id: category.id}))

      assert Enum.any?(
               errors_for(error, :category_id),
               &(&1 =~ "no longer exists" and &1 =~ "choose another")
             )
    end
  end

  describe "list_for_month" do
    test "returns only the entries dated within the month, newest first" do
      month = past_month()
      category = category_fixture()

      entry_fixture(category: category, date: Date.add(month, -1), amount: Decimal.new("1.00"))
      early = entry_fixture(category: category, date: past_month_day(2))
      late = entry_fixture(category: category, date: past_month_day(20))

      entry_fixture(
        category: category,
        date: Date.add(Date.end_of_month(month), 1),
        amount: Decimal.new("2.00")
      )

      assert [late.id, early.id] ==
               month.year |> Spending.list_entries_for_month!(month.month) |> Enum.map(& &1.id)
    end

    test "loads the category alongside the entries" do
      month = past_month()
      category = category_fixture(name: "Rent")
      entry_fixture(category: category, date: past_month_day(5))

      assert [entry] = Spending.list_entries_for_month!(month.year, month.month)
      assert entry.category.name == "Rent"
    end
  end

  describe "monthly_summary/2" do
    test "totals each category and the whole month" do
      month = past_month()
      food = category_fixture(name: "Food")
      rent = category_fixture(name: "Rent")

      entry_fixture(category: food, date: past_month_day(2), amount: Decimal.new("12.50"))
      entry_fixture(category: food, date: past_month_day(3), amount: Decimal.new("7.50"))
      entry_fixture(category: rent, date: past_month_day(1), amount: Decimal.new("900.00"))
      # A different month must not leak into these totals.
      entry_fixture(category: rent, date: Date.add(month, -1), amount: Decimal.new("850.00"))

      summary = Spending.monthly_summary(month.year, month.month)

      assert [%{category_name: "Food"}, %{category_name: "Rent"}] = summary.rows
      assert Decimal.equal?(Enum.at(summary.rows, 0).total, Decimal.new("20.00"))
      assert Decimal.equal?(Enum.at(summary.rows, 1).total, Decimal.new("900.00"))
      assert Decimal.equal?(summary.total, Decimal.new("920.00"))
      assert summary.entry_count == 3
    end

    test "is zero for a month with no entries" do
      summary = Spending.monthly_summary(2019, 7)

      assert summary.rows == []
      assert Decimal.equal?(summary.total, Decimal.new("0.00"))
    end
  end

  describe "categories" do
    test "are listed alphabetically" do
      default_categories_fixture()

      assert ~w(Entertainment Food Rent Transport) ==
               Spending.list_categories!() |> Enum.map(& &1.name)
    end

    test "names are unique (INV-022)" do
      category_fixture(name: "Food")
      assert {:error, %Ash.Error.Invalid{}} = Spending.create_category("Food")
    end
  end
end
