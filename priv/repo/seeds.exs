# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It is idempotent — re-running it leaves the database unchanged.

alias SpendLog.Spending

# The default category set (TRM-004). Names are globally unique (INV-022), so creating one that is
# already there is an expected no-op rather than an error.
existing = MapSet.new(Spending.list_categories!(), & &1.name)

for name <- ~w(Food Transport Rent Entertainment), name not in existing do
  Spending.create_category!(name)
end
