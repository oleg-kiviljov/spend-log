defmodule SpendLog.Spending.Money do
  @moduledoc """
  Renders EUR amounts for display.

  Formatting happens here — on the server — rather than in Vue, for two reasons that both bite
  silently. Production SSR runs on QuickBEAM, whose JS runtime ships no `Intl.NumberFormat`; a
  `toLocaleString` there falls back to `toString()`, so you would get `12.34` in production and
  `€12.34` in development. And routing an amount through JS at all would put money in a float,
  which Iron Law #4 forbids. Every amount crosses the wire as a finished string.
  """

  @doc """
  Formats a `Decimal` as EUR with a thousands separator and exactly two decimal places.

      iex> SpendLog.Spending.Money.to_eur(Decimal.new("1234.5"))
      "€1,234.50"

      iex> SpendLog.Spending.Money.to_eur(Decimal.new("0"))
      "€0.00"
  """
  @spec to_eur(Decimal.t()) :: String.t()
  def to_eur(%Decimal{} = amount) do
    [units, cents] =
      amount
      |> Decimal.round(2)
      |> Decimal.abs()
      |> Decimal.to_string(:normal)
      |> String.split(".")

    sign = if Decimal.negative?(amount), do: "-", else: ""

    "#{sign}€#{group_thousands(units)}.#{cents}"
  end

  # Decimal.to_string(:normal) always emits a fractional part for a 2dp-rounded value, so the
  # split above is total — but be explicit rather than relying on that.
  defp group_thousands(units) do
    units
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
