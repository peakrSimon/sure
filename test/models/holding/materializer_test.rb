require "test_helper"

class Holding::MaterializerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test", balance: 20000, cash_balance: 20000, currency: "USD", accountable: Investment.new)
    @aapl = securities(:aapl)
    @msft = securities(:msft)
  end

  test "syncs holdings" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)

    # Should have yesterday's and today's holdings
    assert_difference "@account.holdings.count", 2 do
      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    end
  end

  # A position that takes in a transfer has no cost basis this app can know.
  # A nil from the calculator alone left the previous calculated figure
  # standing — the stale number reporting a transferred coin as if it had been
  # bought on the day it arrived. `avg_cost` reads that stored value before it
  # ever reaches the transfer guard, so the guard was only protecting holdings
  # that had nothing stored at all.
  #
  # Materialised first and relabelled after, because that is the case that
  # matters: a position already carrying a figure worked out before anyone
  # knew the movement was a transfer.
  test "a transfer clears a cost basis this app had worked out" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    assert_equal 200, latest_holding.cost_basis.to_d, "nothing was stored to clear"

    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_nil latest_holding.cost_basis, "the stale calculated figure survived the transfer"
    assert_nil latest_holding.cost_basis_source
    assert_nil latest_holding.avg_cost
  end

  test "a sweep in clears a cost basis this app had worked out" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    assert_equal 200, latest_holding.cost_basis.to_d

    @account.trades.each { |trade| trade.update!(investment_activity_label: "Sweep In") }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_nil latest_holding.cost_basis
    assert_nil latest_holding.cost_basis_source
    assert_nil latest_holding.avg_cost
  end

  # A row carrying a figure with no `cost_basis_source` was invisible to
  # `load_existing_holdings_map`, so the clearing above saw no existing holding
  # and left the stale basis standing — the rows least able to justify the
  # number they hold being the ones that kept it.
  test "a transfer clears a stored basis that never recorded where it came from" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    @account.holdings.where(security: @aapl).update_all(cost_basis: 200, cost_basis_source: nil)
    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_nil latest_holding.cost_basis, "a source-less figure outlived the transfer"
  end
  # Somebody asserted what this position cost them, which is exactly what the
  # app cannot work out for a transfer. Theirs to keep.
  test "a transfer leaves a provider cost basis alone" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    @account.holdings.where(security: @aapl).update_all(cost_basis: 150, cost_basis_source: "provider")
    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_equal 150, latest_holding.cost_basis.to_d
  end

  # An ordinary purchase is untouched: the exclusion keys off the label, and
  # most rows carry none at all.
  test "an ordinary purchase still gets its calculated basis" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)

    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_equal 200, latest_holding.cost_basis.to_d
  end

  test "purges stale holdings for unlinked accounts" do
    # Since the account has no entries, there should be no holdings
    Holding.create!(account: @account, security: @aapl, qty: 1, price: 100, amount: 100, currency: "USD", date: Date.current)

    assert_difference "Holding.count", -1 do
      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    end
  end

  test "preserves provider cost_basis when trade-derived cost_basis is nil" do
    # Simulate a provider-imported holding with cost_basis (e.g., from SimpleFIN)
    # This is the realistic scenario: linked account with provider holdings but no trades
    provider_cost_basis = BigDecimal("150.00")
    holding = Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      date: Date.current,
      cost_basis: provider_cost_basis
    )

    # Use :reverse strategy (what linked accounts use) - doesn't purge holdings
    # The AAPL holding has no trades, so computed cost_basis is nil
    # The materializer should preserve the provider cost_basis, not overwrite with nil
    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    holding.reload
    assert_equal provider_cost_basis, holding.cost_basis,
      "Provider cost_basis should be preserved when no trades exist for this security"
  end

  test "updates cost_basis when trade-derived cost_basis is available" do
    # Create a holding with provider cost_basis
    Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      date: Date.current,
      cost_basis: BigDecimal("150.00")  # Provider says $150
    )

    # Create a trade that gives us a different cost basis
    create_trade(@aapl, account: @account, qty: 10, price: 180, date: Date.current)

    # Use :reverse strategy - with trades, it should compute cost_basis from them
    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    holding = @account.holdings.find_by(security: @aapl, date: Date.current)
    assert_equal BigDecimal("180.00"), holding.cost_basis,
      "Trade-derived cost_basis should override provider cost_basis when available"
  end

  test "recalculates calculated cost_basis when new trades are added" do
    date = Date.current

    create_trade(@aapl, account: @account, qty: 1, price: 3000, date: date)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    holding = @account.holdings.find_by!(security: @aapl, date: date, currency: "USD")
    assert_equal "calculated", holding.cost_basis_source
    assert_equal BigDecimal("3000.0"), holding.cost_basis

    create_trade(@aapl, account: @account, qty: 1, price: 2500, date: date)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    holding.reload
    assert_equal "calculated", holding.cost_basis_source
    assert_equal BigDecimal("2750.0"), holding.cost_basis
  end

  test "carry-forward is a no-op for forward-strategy accounts without provider holdings" do
    create_trade(@aapl, account: @account, qty: 5, price: 200, date: Date.current)

    assert_nothing_raised do
      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    end

    today_holding = @account.holdings.find_by!(security: @aapl, date: Date.current, currency: "USD")
    assert_equal "calculated", today_holding.cost_basis_source
    assert_equal BigDecimal("200.00"), today_holding.cost_basis,
      "Forward strategy with no provider rows should compute cost_basis from trades normally"
  end

  private

    def latest_holding
      @account.holdings.where(security: @aapl).order(:date).last
    end
end
