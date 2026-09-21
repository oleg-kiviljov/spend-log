defmodule SpendLog.Spending.MoneyTest do
  use ExUnit.Case, async: true

  doctest SpendLog.Spending.Money

  alias SpendLog.Spending.Money

  describe "to_eur/1" do
    test "always shows two decimal places" do
      assert Money.to_eur(Decimal.new("5")) == "€5.00"
      assert Money.to_eur(Decimal.new("5.1")) == "€5.10"
      assert Money.to_eur(Decimal.new("5.00")) == "€5.00"
    end

    test "groups thousands" do
      assert Money.to_eur(Decimal.new("999.99")) == "€999.99"
      assert Money.to_eur(Decimal.new("1000")) == "€1,000.00"
      assert Money.to_eur(Decimal.new("12345.67")) == "€12,345.67"
      assert Money.to_eur(Decimal.new("1000000.00")) == "€1,000,000.00"
    end

    test "rounds to the nearest cent rather than truncating" do
      assert Money.to_eur(Decimal.new("1.005")) == "€1.01"
      assert Money.to_eur(Decimal.new("1.004")) == "€1.00"
    end

    test "keeps the sign outside the symbol" do
      assert Money.to_eur(Decimal.new("-42.50")) == "-€42.50"
    end
  end
end
