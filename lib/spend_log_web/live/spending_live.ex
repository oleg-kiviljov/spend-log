defmodule SpendLogWeb.SpendingLive do
  @moduledoc """
  The main page: one month of spending, its summary, and the pop-up that adds to it.

  The whole screen is a single Vue island (`SpendingPage`). LiveView owns every piece of state the
  user can see — the selected month, the entry list, the summary and the form — and pushes it down
  as props; the only state Vue keeps to itself is whether the pop-up is open, which is a purely
  visual toggle.

  Two things are deliberately done on this side of the boundary:

    * **Every displayed amount and date is formatted here**, in Elixir. Production SSR runs on
      QuickBEAM, whose JS has no `Intl.NumberFormat`/`Intl.DateTimeFormat`, so a client-side
      `toLocaleString` would quietly render `12.34` in production and `€12.34` in development. It
      also keeps money out of a JS float (Iron Law #4).
    * **The selected month is a single value** (`@month`) that both the list and the summary are
      derived from, which is what makes it impossible for the two to disagree (INV-021).
  """
  use SpendLogWeb, :live_view

  alias SpendLog.Spending
  alias SpendLog.Spending.Entry
  alias SpendLog.Spending.Money
  alias SpendLog.Spending.Month

  @impl true
  def mount(_params, _session, socket) do
    today = Date.utc_today()

    socket =
      socket
      |> assign(:today, today)
      |> assign(:month, Month.from_date(today))
      |> assign(:form, blank_form(today))
      |> assign(:form_error, nil)
      |> assign(:saved_count, 0)
      |> assign(:categories, [])
      |> assign(:entries, [])
      |> assign(:summary, Spending.summarize([]))
      # `nil` means "nothing has ever been recorded", which is also what the disconnected paint
      # shows: the first-run prompt, with no arrows. The connected mount corrects it a moment later.
      |> assign(:earliest_month, nil)

    # Iron Law #1 — no database work in the disconnected mount. The first paint renders the empty
    # states, which the Vue components handle as a first-class case.
    {:ok, if(connected?(socket), do: load_month(socket), else: socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.vue
        v-component="SpendingPage"
        id="spending-page"
        month={month_prop(@month, @today, @earliest_month)}
        summary={summary_prop(@summary)}
        entries={Enum.map(@entries, &entry_prop/1)}
        categories={Enum.map(@categories, &%{id: &1.id, name: &1.name})}
        form={@form}
        form_error={@form_error}
        today={Date.to_iso8601(@today)}
        saved_count={@saved_count}
      />
    </Layouts.app>
    """
  end

  # A client can push any event with any payload — not just the ones the Vue island sends — so
  # every clause below matches on the *shape* it needs, and `handle_event/3` ends with a catch-all
  # that ignores anything else. Without the `is_map` guards, a `{"form": "pwn"}` payload reaches
  # `AshPhoenix.Form.validate/3` and takes the LiveView process down with a BadMapError.
  @impl true
  def handle_event("validate", %{"form" => params}, socket) when is_map(params) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params)

    {:noreply, socket |> assign(:form, to_vue_form(form)) |> assign(:form_error, nil)}
  end

  def handle_event("submit", %{"form" => params}, socket) when is_map(params) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, entry} ->
        # The blank form is what actually clears the inputs; `reset: true` clears the *touched*
        # state so the fresh form does not immediately paint "required" under every field. Both
        # halves are needed — see the LiveVue useLiveForm reply path.
        {:reply, %{reset: true},
         socket
         |> assign(:form, blank_form(socket.assigns.today))
         |> assign(:form_error, nil)
         |> update(:saved_count, &(&1 + 1))
         |> load_month()
         |> note_if_off_month(entry)}

      {:error, form} ->
        {:reply, %{reset: false},
         socket
         |> assign(:form, to_vue_form(form))
         |> assign(:form_error, form_level_error(form))
         # A category may have vanished since the pop-up was opened; refresh the picker so the
         # user's next choice is from a list that is actually current.
         |> assign(:categories, Spending.list_categories!())}
    end
  end

  def handle_event("open_entry_form", _params, socket) do
    # Rebuilding on open keeps the date correct across a midnight rollover, drops any errors left
    # over from an abandoned attempt, and re-reads the categories.
    {:noreply,
     socket
     |> assign(:today, Date.utc_today())
     |> assign(:form, blank_form(Date.utc_today()))
     |> assign(:form_error, nil)
     |> assign(:categories, Spending.list_categories!())}
  end

  def handle_event("select_month", %{"month" => month}, socket) when is_binary(month) do
    # The month comes from the client, so it is parsed strictly rather than coerced, and a month
    # outside the navigable range is refused outright (Iron Law #8). Disabling the arrows is an
    # affordance; this is the enforcement — a hand-crafted payload must not be able to park the
    # session in a month the user was never offered.
    case Month.parse(month) do
      {:ok, _year_and_month} ->
        if navigable?(month, socket.assigns) do
          {:noreply,
           socket
           |> assign(:month, month)
           |> load_month()
           # The list is replaced wholesale, so the viewport has to go back to the top or the user
           # lands mid-way down a month they have not seen (LiveVue: consumed by `useLiveEvent`).
           |> push_event("scroll_to_top", %{})}
        else
          {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  # Anything that did not match a clause above is a payload this page never sends. Drop it rather
  # than letting it crash the session.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # The two ends of the navigable range. Nothing recorded at all means nothing to navigate.
  defp navigable?(_month, %{earliest_month: nil}), do: false

  defp navigable?(month, %{earliest_month: earliest, today: today}) do
    not Month.future?(month, today) and not Month.before?(month, earliest)
  end

  defp load_month(socket) do
    {:ok, {year, month}} = Month.parse(socket.assigns.month)
    entries = Spending.list_entries_for_month!(year, month)

    socket
    |> assign(:entries, entries)
    # Recomputed on every load because a back-dated entry can move the floor backwards, which has
    # to re-enable a back arrow that was disabled a moment ago.
    |> assign(:earliest_month, Spending.earliest_month())
    # Summarised from the very list being displayed, so the two can never disagree (INV-021) and
    # the totals cost no extra query.
    |> assign(:summary, Spending.summarize(entries))
    |> assign(:categories, Spending.list_categories!())
  end

  # An entry saved for a date outside the month on screen is saved, but invisible. Say so rather
  # than letting it look like nothing happened.
  defp note_if_off_month(socket, %Entry{date: date}) do
    entry_month = Month.from_date(date)

    if entry_month == socket.assigns.month do
      socket
    else
      put_flash(socket, :info, "Saved to #{Month.label(entry_month)} — switch months to see it.")
    end
  end

  defp blank_form(today) do
    Entry
    |> AshPhoenix.Form.for_create(:create,
      domain: Spending,
      as: "form",
      params: %{
        "amount" => "",
        "date" => Date.to_iso8601(today),
        "category_id" => "",
        "note" => ""
      }
    )
    |> to_vue_form()
  end

  # Errors AshPhoenix could not attach to a field would be encoded under a `null` key and never
  # reach the user. Surface them as a banner instead of dropping them on the floor.
  defp form_level_error(form) do
    form
    |> AshPhoenix.Form.errors(for_path: :all)
    |> Map.get([], [])
    |> Enum.find_value(fn
      {nil, message} -> message
      _field_error -> nil
    end)
  end

  # `nil` on either end disables that arrow. The range is bounded by real data on one side and by
  # the calendar on the other: a Spending Entry can only be dated today or earlier, so there is
  # nothing to look at after the current month, and nothing to look at before the first entry ever
  # recorded. `earliest` is `nil` when nothing has ever been recorded — then there is no navigation
  # at all, and the page shows the first-run prompt instead of a list.
  defp month_prop(month, today, earliest) do
    prev = Month.previous(month)
    next = Month.next(month)

    %{
      value: month,
      label: Month.label(month),
      earliest: earliest,
      prev: if(earliest && not Month.before?(prev, earliest), do: prev),
      next: if(earliest && not Month.future?(next, today), do: next),
      is_current: month == Month.from_date(today)
    }
  end

  defp summary_prop(summary) do
    %{
      rows:
        Enum.map(summary.rows, fn row ->
          %{
            category_id: row.category_id,
            category_name: row.category_name,
            total_display: Money.to_eur(row.total),
            share: share(row.total, summary.total)
          }
        end),
      total_display: Money.to_eur(summary.total),
      entry_count: summary.entry_count
    }
  end

  # A 0..100 percentage for the summary bars. Rounded to a whole number and computed here so the
  # client never does arithmetic on money.
  defp share(total, grand_total) do
    if Decimal.positive?(grand_total) do
      total
      |> Decimal.div(grand_total)
      |> Decimal.mult(100)
      |> Decimal.round(0)
      |> Decimal.to_integer()
    else
      0
    end
  end

  defp entry_prop(entry) do
    %{
      id: entry.id,
      date: Date.to_iso8601(entry.date),
      date_display: Month.label_date(entry.date),
      amount_display: Money.to_eur(entry.amount),
      note: entry.note,
      category_id: entry.category_id,
      category_name: entry.category.name
    }
  end
end
