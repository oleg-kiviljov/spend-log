defmodule SpendLog.Spending.MonthTest do
  use ExUnit.Case, async: true

  doctest SpendLog.Spending.Month

  alias SpendLog.Spending.Month

  describe "parse/1" do
    test "rejects anything that is not exactly YYYY-MM" do
      # This value comes from the client, so the rejections matter more than the acceptances.
      for bad <- ["2026-9", "26-09", "2026-00", "2026-13", "2026/09", "2026-09-01", "", "  "] do
        assert Month.parse(bad) == :error, "expected #{inspect(bad)} to be rejected"
      end

      assert Month.parse(nil) == :error
      assert Month.parse(%{}) == :error
      assert Month.parse(202_609) == :error
    end

    test "accepts a well-formed month" do
      assert Month.parse("2026-01") == {:ok, {2026, 1}}
      assert Month.parse("2026-12") == {:ok, {2026, 12}}
    end
  end

  describe "previous/1 and next/1" do
    test "roll over the year boundary" do
      assert Month.previous("2026-01") == "2025-12"
      assert Month.next("2026-12") == "2027-01"
    end

    test "step within a year" do
      assert Month.previous("2026-09") == "2026-08"
      assert Month.next("2026-09") == "2026-10"
    end
  end

  describe "future?/2" do
    test "compares against the month containing the given day, not the day itself" do
      # Deliberately far from the real today: an implementation that ignored the argument and read
      # the system clock would call 2020-06 a past month and fail here.
      mid_month = ~D[2020-05-15]

      refute Month.future?("2020-05", mid_month)
      refute Month.future?("2020-04", mid_month)
      assert Month.future?("2020-06", mid_month)
    end
  end

  describe "labels" do
    test "name the month" do
      assert Month.label("2026-09") == "September 2026"
      assert Month.label("2026-01") == "January 2026"
    end

    test "render a single date" do
      assert Month.label_date(~D[2026-09-21]) == "21 Sep 2026"
      assert Month.label_date(~D[2026-01-01]) == "1 Jan 2026"
    end
  end

  describe "from_date/1" do
    test "drops the day" do
      assert Month.from_date(~D[2026-09-21]) == "2026-09"
      assert Month.from_date(~D[2026-01-01]) == "2026-01"
    end
  end
end
