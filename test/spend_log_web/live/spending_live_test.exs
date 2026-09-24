defmodule SpendLogWeb.SpendingLiveTest do
  @moduledoc """
  Cover for the add-entry pop-up as the user meets it, driven through the same events the Vue
  island pushes.

  Assertions are on the **props** the island receives rather than on rendered markup: a LiveVue
  island renders as a `data-props` blob, so matching HTML here would be matching Nuxt UI internals,
  not behaviour. `config :live_vue, enable_props_diff: false` (config/test.exs) is what makes
  `get_vue/2` return the full props on every render.
  """
  use SpendLogWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import SpendLog.SpendingFixtures

  alias SpendLog.Spending
  alias SpendLog.Spending.Month

  @island [id: "spending-page"]

  # A fixed, safely-past month, so the "January 2025" header format is asserted against a real month
  # name rather than whatever month the suite happens to run in.
  @january "2025-01"

  defp props(view), do: LiveVue.Test.get_vue(view, @island).props

  defp today_iso, do: Date.to_iso8601(Date.utc_today())

  defp this_month, do: Month.from_date(Date.utc_today())

  defp next_month, do: Date.utc_today() |> Date.shift(month: 1) |> Month.from_date()

  defp month_of(view), do: props(view)["month"]

  defp go_to(view, month), do: render_hook(view, "select_month", %{"month" => month})

  defp entry_on(date, amount, category) do
    entry_fixture(category: category, date: Date.from_iso8601!(date), amount: Decimal.new(amount))
  end

  # Three months of history, all far enough in the past that the clock cannot affect the assertions.
  # The January entries are inserted out of date order so a newest-first assertion can really fail.
  defp january_history do
    category = category_fixture(name: "Food")

    entry_on("2025-01-05", "10.00", category)
    entry_on("2025-01-20", "30.00", category)
    entry_on("2025-01-12", "20.00", category)
    entry_on("2025-02-14", "40.00", category)
    entry_on("2025-03-02", "50.00", category)

    category
  end

  # The payload `useLiveForm` sends: every field present, and `category_id` nil rather than "" when
  # nothing is chosen (the component's `prepareData` does that).
  defp form_params(overrides) do
    Map.merge(
      %{
        "amount" => "12.34",
        "date" => today_iso(),
        "category_id" => nil,
        "note" => ""
      },
      overrides
    )
  end

  defp submit(view, overrides) do
    render_hook(view, "submit", %{"form" => form_params(overrides)})
  end

  defp errors_for(view, field) do
    props(view)["form"]["errors"] |> Map.get(field, []) |> List.wrap()
  end

  setup %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    %{view: view, html: html, conn: conn}
  end

  describe "the main page" do
    test "renders the SpendingPage island", %{view: view, html: html} do
      assert html =~ "spending-page"
      assert LiveVue.Test.get_vue(view, @island).component == "SpendingPage"
    end

    test "shows the current month, with no next month to page into", %{view: view} do
      month = props(view)["month"]

      assert month["value"] == String.slice(today_iso(), 0, 7)
      assert month["is_current"] == true
      assert month["next"] == nil
    end
  end

  describe "browsing by month" do
    # 723530cc5220
    test "shows only the selected month, newest first, under a 'January 2025' header", %{
      conn: conn
    } do
      january_history()
      {:ok, view, _html} = live(conn, ~p"/")

      go_to(view, @january)

      assert month_of(view)["value"] == @january
      assert month_of(view)["label"] == "January 2025"

      # Only January's three entries — February's and March's are excluded.
      assert ["2025-01-20", "2025-01-12", "2025-01-05"] ==
               Enum.map(props(view)["entries"], & &1["date"])

      # And the summary moved with the list (INV-021).
      assert props(view)["summary"]["total_display"] == "€60.00"
    end

    # 723530cc5220
    test "jumps the list back to the top on each navigation", %{conn: conn} do
      january_history()
      {:ok, view, _html} = live(conn, ~p"/")

      # The first move away from the current month...
      go_to(view, "2025-03")
      assert_push_event(view, "scroll_to_top", %{})

      # ...and every move after it.
      go_to(view, "2025-02")
      assert_push_event(view, "scroll_to_top", %{})

      # Including a move to a month with nothing in it — the list still has to go back to the top,
      # because the previous month's rows are what the user is currently scrolled through.
      go_to(view, "2025-04")
      assert props(view)["entries"] == []
      assert_push_event(view, "scroll_to_top", %{})
    end

    # 723530cc5220
    test "does not jump to the top when the navigation was refused", %{conn: conn} do
      january_history()
      {:ok, view, _html} = live(conn, ~p"/")

      # Before the earliest entry, after today, and not a month at all.
      go_to(view, "2024-12")
      go_to(view, next_month())
      go_to(view, "not-a-month")

      refute_push_event(view, "scroll_to_top", %{})
    end

    # 6e5e8778294c
    test "refuses to page forward past the current month", %{conn: conn} do
      january_history()
      # Read the clock once: reading it again below could straddle a month boundary and compare
      # two different "today"s.
      today = Date.utc_today()
      entry_fixture(date: today)
      {:ok, view, _html} = live(conn, ~p"/")

      # The forward arrow is inert on the current month...
      assert month_of(view)["is_current"] == true
      assert month_of(view)["next"] == nil

      # ...and pressing it anyway leaves the user exactly where they were.
      go_to(view, today |> Date.shift(month: 1) |> Month.from_date())

      assert month_of(view)["value"] == Month.from_date(today)
    end

    # 1cb6c8f0c344
    test "refuses to page back past the month holding the earliest entry", %{conn: conn} do
      january_history()
      {:ok, view, _html} = live(conn, ~p"/")

      go_to(view, @january)

      # January 2025 holds the earliest entry, so the back arrow is inert...
      assert month_of(view)["earliest"] == @january
      assert month_of(view)["prev"] == nil
      # ...while the forward arrow still works, since today is well after January 2025.
      assert month_of(view)["next"] == "2025-02"

      # ...and pressing back anyway leaves the user on the earliest available month.
      go_to(view, "2024-12")

      assert month_of(view)["value"] == @january

      assert Enum.map(props(view)["entries"], & &1["date"]) == [
               "2025-01-20",
               "2025-01-12",
               "2025-01-05"
             ]
    end

    # 1cb6c8f0c344
    test "offers the back arrow again once an older entry moves the floor", %{conn: conn} do
      category = january_history()
      {:ok, view, _html} = live(conn, ~p"/")

      go_to(view, @january)
      assert month_of(view)["prev"] == nil

      # A back-dated entry pushes the earliest month further back, which has to re-enable the arrow
      # that was inert a moment ago.
      entry_on("2024-11-30", "5.00", category)
      go_to(view, @january)

      assert month_of(view)["earliest"] == "2024-11"
      assert month_of(view)["prev"] == "2024-12"

      go_to(view, "2024-12")
      assert month_of(view)["value"] == "2024-12"
    end

    # 098bcfa94593
    test "shows the placeholder and offers no arrows when nothing was ever recorded", %{
      view: view
    } do
      month = month_of(view)

      # `earliest: nil` is what puts the first-run placeholder in place of the list. Asserted as a
      # *present* key first: a bare `== nil` would also pass if the prop had never been sent.
      assert Map.has_key?(month, "earliest")
      assert month["earliest"] == nil
      assert props(view)["entries"] == []

      # ...and it withholds both arrows, not just one of them.
      assert month["prev"] == nil
      assert month["next"] == nil
    end

    # 098bcfa94593
    test "refuses every navigation while nothing has ever been recorded", %{view: view} do
      before = month_of(view)

      for month <- [@january, "2024-12", this_month()] do
        go_to(view, month)
      end

      assert month_of(view) == before
      refute_push_event(view, "scroll_to_top", %{})
    end

    # 098bcfa94593
    test "swaps the placeholder for real navigation as soon as the first entry lands", %{
      view: view
    } do
      assert month_of(view)["earliest"] == nil

      submit(view, %{"category_id" => category_fixture().id})

      # The placeholder is gone and the range now has a floor.
      assert month_of(view)["earliest"] == this_month()
      assert length(props(view)["entries"]) == 1
    end
  end

  describe "the add-entry pop-up's defaults" do
    test "pre-fills the date with today and leaves the other fields blank", %{view: view} do
      values = props(view)["form"]["values"]

      assert values["date"] == today_iso()
      assert values["amount"] == ""
      assert values["category_id"] == ""
      assert values["note"] == ""
    end

    test "offers the available categories in alphabetical order", %{view: view} do
      # Created out of order on purpose, so this assertion can actually fail.
      default_categories_fixture()
      render_hook(view, "open_entry_form", %{})

      assert ~w(Entertainment Food Rent Transport) ==
               Enum.map(props(view)["categories"], & &1["name"])
    end
  end

  describe "hostile payloads" do
    # A client can push any event with any payload. None of these should take the session down.
    test "a non-map form payload does not crash the session", %{view: view} do
      for payload <- [%{"form" => "pwn"}, %{"form" => []}, %{"form" => 1}, %{}] do
        render_hook(view, "validate", payload)
        render_hook(view, "submit", payload)
      end

      assert props(view)["form"]["values"]["date"] == today_iso()
    end

    test "a malformed select_month payload does not crash the session", %{view: view} do
      before = props(view)["month"]

      for payload <- [%{}, %{"month" => nil}, %{"month" => 202_609}, %{"month" => %{}}] do
        render_hook(view, "select_month", payload)
      end

      assert props(view)["month"] == before
    end

    test "an unknown event is ignored", %{view: view} do
      render_hook(view, "definitely_not_an_event", %{"anything" => "at all"})

      assert props(view)["month"] != nil
    end
  end

  # b44b5c13da4f
  describe "saving an entry" do
    setup do
      %{category: category_fixture(name: "Food")}
    end

    test "saves it, lists it under the month, and counts it in the summary", %{
      view: view,
      category: category
    } do
      submit(view, %{"amount" => "12.34", "category_id" => category.id, "note" => "Lunch"})

      assert [entry] = props(view)["entries"]
      assert entry["amount_display"] == "€12.34"
      assert entry["category_name"] == "Food"
      assert entry["note"] == "Lunch"
      assert entry["date"] == today_iso()

      summary = props(view)["summary"]
      assert summary["total_display"] == "€12.34"
      assert summary["entry_count"] == 1
      assert [%{"category_name" => "Food", "total_display" => "€12.34"}] = summary["rows"]
    end

    test "resets the pop-up so another entry can be logged straight away", %{
      view: view,
      category: category
    } do
      submit(view, %{"amount" => "12.34", "category_id" => category.id, "note" => "Lunch"})

      form = props(view)["form"]

      # Every field is back to its default — the amount, category and note blank, the date today.
      # (`_form_type`/`_touched` are AshPhoenix's own hidden fields, not user input.)
      assert form["values"]["amount"] == ""
      assert form["values"]["category_id"] == ""
      assert form["values"]["note"] == ""
      assert form["values"]["date"] == today_iso()

      assert form["errors"] == %{}
      assert props(view)["saved_count"] == 1
    end

    test "replies with reset: true so the client clears its touched state", %{
      view: view,
      category: category
    } do
      # The other half of the reset: without this reply the freshly blanked form would keep the
      # previous submit's touched state and immediately paint "required" under every field.
      submit(view, %{"category_id" => category.id})

      assert_reply(view, %{reset: true})
    end

    test "supports decimal amounts and adds them up", %{view: view, category: category} do
      submit(view, %{"amount" => "0.99", "category_id" => category.id})
      submit(view, %{"amount" => "10.50", "category_id" => category.id})
      submit(view, %{"amount" => "1.05", "category_id" => category.id})

      # The 0.99 was refused; only the two valid ones count.
      assert props(view)["summary"]["total_display"] == "€11.55"
      assert props(view)["saved_count"] == 2
    end

    test "accepts a past date and files it under that month", %{view: view, category: category} do
      last_month = Date.utc_today() |> Date.beginning_of_month() |> Date.shift(month: -1)
      date = Date.to_iso8601(last_month)

      submit(view, %{"date" => date, "category_id" => category.id})

      # Saved, but not in the month on screen — so the list stays empty and the user is told.
      assert props(view)["entries"] == []
      assert render(view) =~ "switch months to see it"

      render_hook(view, "select_month", %{"month" => String.slice(date, 0, 7)})
      assert [%{"date" => ^date}] = props(view)["entries"]
    end

    test "accepts the inclusive bounds €1.00 and €1,000,000.00", %{view: view, category: category} do
      submit(view, %{"amount" => "1.00", "category_id" => category.id})
      submit(view, %{"amount" => "1000000.00", "category_id" => category.id})

      assert props(view)["saved_count"] == 2
      assert props(view)["summary"]["total_display"] == "€1,000,001.00"
    end

    test "accepts today's date", %{view: view, category: category} do
      submit(view, %{"date" => today_iso(), "category_id" => category.id})

      assert [%{"date" => date}] = props(view)["entries"]
      assert date == today_iso()
    end

    test "the note is optional", %{view: view, category: category} do
      submit(view, %{"category_id" => category.id, "note" => ""})

      assert [%{"note" => nil}] = props(view)["entries"]
    end
  end

  # 9894fa7e321e
  test "refuses an amount below €1.00 and names the minimum", %{view: view} do
    category = category_fixture()

    submit(view, %{"amount" => "0.99", "category_id" => category.id})

    assert "the minimum allowed amount is €1.00" in errors_for(view, "amount")
    assert props(view)["form"]["valid"] == false
    assert props(view)["entries"] == []
  end

  # af0c9f158f8a
  test "refuses an amount above €1,000,000.00 and names the maximum", %{view: view} do
    category = category_fixture()

    submit(view, %{"amount" => "1000000.01", "category_id" => category.id})

    assert "the maximum allowed amount is €1,000,000.00" in errors_for(view, "amount")
    assert props(view)["entries"] == []
  end

  # 300b5b0d6fd6
  test "refuses a date beyond today", %{view: view} do
    category = category_fixture()
    tomorrow = Date.utc_today() |> Date.add(1) |> Date.to_iso8601()

    submit(view, %{"date" => tomorrow, "category_id" => category.id})

    assert Enum.any?(errors_for(view, "date"), &(&1 =~ "cannot be in the future"))
    assert props(view)["entries"] == []
  end

  # b7947ce9857f
  test "refuses a category that no longer exists and prompts for another", %{view: view} do
    category = category_fixture(name: "Holidays")
    render_hook(view, "open_entry_form", %{})
    assert Enum.any?(props(view)["categories"], &(&1["id"] == category.id))

    Spending.delete_category!(category)
    submit(view, %{"category_id" => category.id})

    assert Enum.any?(errors_for(view, "category_id"), &(&1 =~ "no longer exists"))
    assert Enum.any?(errors_for(view, "category_id"), &(&1 =~ "choose another"))
    assert props(view)["entries"] == []
    # The picker is refreshed so the user's next choice comes from a current list.
    refute Enum.any?(props(view)["categories"], &(&1["id"] == category.id))
  end

  # 087d6b223af9
  test "refuses an entry with no category selected and prompts for one", %{view: view} do
    category_fixture()

    submit(view, %{"category_id" => nil})

    assert "please select a category" in errors_for(view, "category_id")
    assert props(view)["entries"] == []
  end

  describe "validate" do
    test "surfaces errors as the user types without saving anything", %{view: view} do
      category = category_fixture()

      render_hook(view, "validate", %{
        "form" => form_params(%{"amount" => "0.50", "category_id" => category.id})
      })

      assert "the minimum allowed amount is €1.00" in errors_for(view, "amount")
      assert props(view)["entries"] == []
      assert props(view)["saved_count"] == 0
    end
  end

  describe "open_entry_form" do
    test "clears errors left over from an abandoned attempt", %{view: view} do
      submit(view, %{"amount" => "0.50", "category_id" => category_fixture().id})
      refute errors_for(view, "amount") == []

      render_hook(view, "open_entry_form", %{})

      assert props(view)["form"]["errors"] == %{}
      assert props(view)["form"]["values"]["date"] == today_iso()
    end
  end

  describe "select_month" do
    test "moves the list and the summary together", %{conn: conn} do
      last_month = Date.utc_today() |> Date.beginning_of_month() |> Date.shift(month: -1)
      category = category_fixture(name: "Rent")

      entry_fixture(category: category, date: last_month, amount: Decimal.new("900.00"))
      entry_fixture(category: category, date: Date.utc_today(), amount: Decimal.new("20.00"))

      # Mounted after the fixtures exist, so the first load already sees them.
      {:ok, view, _html} = live(conn, ~p"/")

      assert props(view)["summary"]["total_display"] == "€20.00"
      assert length(props(view)["entries"]) == 1

      render_hook(view, "select_month", %{
        "month" => String.slice(Date.to_iso8601(last_month), 0, 7)
      })

      assert props(view)["month"]["value"] == String.slice(Date.to_iso8601(last_month), 0, 7)
      assert props(view)["summary"]["total_display"] == "€900.00"
      assert length(props(view)["entries"]) == 1
    end

    test "ignores a month that is not a month", %{view: view} do
      before = props(view)["month"]

      render_hook(view, "select_month", %{"month" => "not-a-month"})

      assert props(view)["month"] == before
    end

    test "refuses to page into the future", %{view: view} do
      before = props(view)["month"]
      next_month = Date.utc_today() |> Date.shift(month: 1) |> Date.to_iso8601()

      render_hook(view, "select_month", %{"month" => String.slice(next_month, 0, 7)})

      assert props(view)["month"] == before
    end
  end
end
