defmodule SpendLog.Spending do
  @moduledoc """
  The spending domain: what was spent, when, and under which label.

  Boundary: everything about a **Spending Entry** (TRM-003) and the **Category** (TRM-004) it is
  filed under, including the **Monthly Summary** (TRM-006) rollup. Money is always a `Decimal` in
  EUR — never a float (Iron Law #4) — and formatting for display lives in `SpendLog.Spending.Money`
  so the server owns every string the client renders.
  """
  use Ash.Domain, extensions: [AshPhoenix]

  alias SpendLog.Spending.Entry
  alias SpendLog.Spending.Month

  resources do
    resource SpendLog.Spending.Category do
      define :list_categories, action: :read
      define :get_category, action: :read, get_by: [:id]
      define :create_category, action: :create, args: [:name]
      define :delete_category, action: :destroy
    end

    resource SpendLog.Spending.Entry do
      define :create_entry, action: :create
      define :get_entry, action: :read, get_by: [:id]
      define :list_entries_for_month, action: :list_for_month, args: [:year, :month]
    end
  end

  @typedoc "A single row of the Monthly Summary — one category and its total for the month."
  @type summary_row :: %{
          category_id: Ash.UUID.t(),
          category_name: String.t(),
          total: Decimal.t()
        }

  @typedoc "Per-category totals plus the grand total for one month (TRM-006)."
  @type summary :: %{rows: [summary_row()], total: Decimal.t(), entry_count: non_neg_integer()}

  @doc """
  Per-category totals and the grand total for `year`/`month`.

  A plain function rather than a generic action: none of Ash's five reasons to prefer an action
  apply (no API extension, no cast inputs, no policies, no transaction). It folds the entries the
  caller already needs for the list view, so the summary costs no extra query — and that shared
  read is what keeps the summary and the list on the same month (INV-021).

  Rows come back sorted by category name, so the summary reads in the same alphabetical order as
  the category picker.
  """
  @spec monthly_summary(pos_integer(), 1..12) :: summary()
  def monthly_summary(year, month) do
    year |> list_entries_for_month!(month) |> summarize()
  end

  @doc """
  The month containing the earliest recorded Spending Entry, or `nil` when none has ever been
  recorded.

  `nil` is the canonical first-run signal — an empty table makes SQL's `MIN()` return `NULL`, so one
  query answers both "has anything ever been recorded?" and "how far back may the user page?". The
  caller never needs a separate existence check.

  A plain function rather than a generic action: none of Ash's five reasons to prefer an action
  apply. `Ash.min/3` rather than a sort-and-limit read action, because this is an aggregate — the
  record itself is not wanted, and `MIN(date)` is an index-only scan over the existing `:date`
  index.
  """
  @spec earliest_month() :: Month.t() | nil
  def earliest_month do
    case Ash.min(Entry, :date, authorize?: false) do
      {:ok, nil} -> nil
      {:ok, %Date{} = date} -> Month.from_date(date)
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  @doc """
  Roll an already-loaded list of entries up into a `t:summary/0`.

  Split out from `monthly_summary/2` so a caller that has just read the month's entries (the
  spending list) can reuse them instead of hitting the database a second time. Entries must have
  `:category` loaded.
  """
  @spec summarize([SpendLog.Spending.Entry.t()]) :: summary()
  def summarize(entries) do
    rows =
      entries
      |> Enum.group_by(& &1.category_id)
      |> Enum.map(fn {category_id, grouped} ->
        %{
          category_id: category_id,
          category_name: hd(grouped).category.name,
          total: sum_amounts(grouped)
        }
      end)
      |> Enum.sort_by(& &1.category_name)

    %{rows: rows, total: sum_amounts(entries), entry_count: length(entries)}
  end

  defp sum_amounts(entries) do
    Enum.reduce(entries, Decimal.new("0.00"), &Decimal.add(&1.amount, &2))
  end
end
