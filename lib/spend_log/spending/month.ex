defmodule SpendLog.Spending.Month do
  @moduledoc """
  The selected calendar month, as a `"YYYY-MM"` string.

  The month is a first-class concept rather than a pair of loose integers because INV-021 hangs on
  it: the Monthly Summary and the spending list must never show different months, which is only
  guaranteed if there is exactly one value both are derived from.

  Month names are rendered here, on the server, for the same reason amounts are — production SSR
  has no `Intl.DateTimeFormat` (see `SpendLog.Spending.Money`).
  """

  @month_names ~w(January February March April May June July August September October November December)
  @short_month_names ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  @typedoc ~s(A calendar month in `"YYYY-MM"` form, e.g. `"2026-09"`.)
  @type t :: String.t()

  @doc ~s(The month containing `date`, or today's month when called with no argument.)
  @spec from_date(Date.t()) :: t()
  def from_date(date \\ Date.utc_today()), do: String.slice(Date.to_iso8601(date), 0, 7)

  @doc """
  Parses a `"YYYY-MM"` string into `{year, month}`.

  Strict on purpose: this reads a value the client supplied, so anything that is not exactly four
  digits, a hyphen and a real month number is rejected rather than coerced (Iron Law #8).

      iex> SpendLog.Spending.Month.parse("2026-09")
      {:ok, {2026, 9}}

      iex> SpendLog.Spending.Month.parse("2026-13")
      :error

      iex> SpendLog.Spending.Month.parse("nope")
      :error
  """
  @spec parse(term()) :: {:ok, {pos_integer(), 1..12}} | :error
  def parse(value) when is_binary(value) do
    case Regex.run(~r/^(\d{4})-(\d{2})$/, value) do
      [_match, year, month] ->
        year = String.to_integer(year)
        month = String.to_integer(month)
        if year > 0 and month in 1..12, do: {:ok, {year, month}}, else: :error

      nil ->
        :error
    end
  end

  def parse(_value), do: :error

  @doc ~s(The month before `month`, e.g. `"2026-01"` -> `"2025-12"`.)
  @spec previous(t()) :: t()
  def previous(month), do: shift(month, -1)

  @doc ~s(The month after `month`, e.g. `"2026-12"` -> `"2027-01"`.)
  @spec next(t()) :: t()
  def next(month), do: shift(month, 1)

  @doc """
  Whether `month` lies after the month containing `today`.

  Used to stop the user paging into months that cannot contain entries yet — a Spending Entry may
  only be dated today or earlier.
  """
  @spec future?(t(), Date.t()) :: boolean()
  def future?(month, today \\ Date.utc_today()), do: month > from_date(today)

  @doc """
  Whether `month` falls before `other`.

  Zero-padded `"YYYY-MM"` sorts lexicographically exactly as it sorts chronologically. That is a
  property of the format, so the comparison lives in the module that owns the format rather than
  being spelled as a bare string compare at each call site.

      iex> SpendLog.Spending.Month.before?("2025-12", "2026-01")
      true

      iex> SpendLog.Spending.Month.before?("2026-01", "2026-01")
      false
  """
  @spec before?(t(), t()) :: boolean()
  def before?(month, other), do: month < other

  @doc ~s(A display label, e.g. `"September 2026"`.)
  @spec label(t()) :: String.t()
  def label(month) do
    {:ok, {year, month_number}} = parse(month)
    "#{Enum.at(@month_names, month_number - 1)} #{year}"
  end

  @doc ~s(A display label for a single date, e.g. `"21 Sep 2026"`.)
  @spec label_date(Date.t()) :: String.t()
  def label_date(%Date{} = date) do
    "#{date.day} #{Enum.at(@short_month_names, date.month - 1)} #{date.year}"
  end

  defp shift(month, offset) do
    {:ok, {year, month_number}} = parse(month)

    year
    |> Date.new!(month_number, 1)
    |> Date.shift(month: offset)
    |> from_date()
  end
end
