defmodule SpendLog.Spending.Entry.Preparations.FilterByMonth do
  @moduledoc """
  Narrows a read to the calendar month given by the `:year` and `:month` arguments.

  A custom preparation rather than `build(filter: …)` because the bounds are date arithmetic over
  runtime arguments (how many days September has is not something a literal filter can express).
  """
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    year = Ash.Query.get_argument(query, :year)
    month = Ash.Query.get_argument(query, :month)

    case Date.new(year, month, 1) do
      {:ok, first} ->
        last = Date.end_of_month(first)
        Ash.Query.filter(query, date >= ^first and date <= ^last)

      {:error, _reason} ->
        Ash.Query.add_error(query, field: :month, message: "is not a valid year/month")
    end
  end
end
