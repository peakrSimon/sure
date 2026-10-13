require "test_helper"

class Holding::CurrentForInvestmentAccountsTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "Investment",
      balance: 2100,
      currency: "USD",
      accountable: Investment.new
    )
  end

  test "returns the latest holding per security for a manual account" do
    security = Security.create!(ticker: "AAPL", name: "Apple")
    create_holding_for_security(security, date: 2.days.ago.to_date, qty: 1)
    latest = create_holding_for_security(security, date: Date.current, qty: 2)

    assert_equal [ latest.id ], described_query.pluck(:id)
  end

  private
    def described_query
      Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation
    end

    def create_holding(ticker, date:)
      security = Security.create!(ticker: ticker, name: ticker)
      create_holding_for_security(security, date: date)
    end

    def create_holding_for_security(security, date:, qty: 1)
      @account.holdings.create!(
        security: security,
        date: date,
        qty: qty,
        price: 100,
        amount: qty * 100,
        currency: "USD"
      )
    end
end
