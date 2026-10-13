require "test_helper"

class Account::CurrentBalanceManagerTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  # -------------------------------------------------------------------------------------------------
  # Manual account current balance management
  #
  # Manual accounts do not manage `current_anchor` valuations and have "auto-update strategies" to set the current balance.
  # -------------------------------------------------------------------------------------------------

  test "when one or more reconciliations exist, append new reconciliation to represent the current balance" do
    account = @family.accounts.create!(
      name: "Test",
      balance: 1000,
      cash_balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )

    # A reconciliation tells us that the user is tracking this account's value with balance-only updates
    account.entries.create!(
      date: 30.days.ago.to_date,
      name: "First manual recon valuation",
      amount: 1200,
      currency: "USD",
      entryable: Valuation.new(kind: "reconciliation")
    )

    manager = Account::CurrentBalanceManager.new(account)

    assert_equal 1, account.valuations.count

    # Here, we assume user is once again "overriding" the balance to 1400
    manager.set_current_balance(1400)

    today_valuation = account.entries.valuations.find_by(date: Date.current)

    assert_equal 2, account.valuations.count
    assert_equal 1400, today_valuation.amount

    assert_equal 1400, account.balance
  end

  test "all manual non cash accounts append reconciliations for current balance updates" do
    [ Property, Vehicle, OtherAsset, Loan, OtherLiability ].each do |account_type|
      account = @family.accounts.create!(
        name: "Test",
        balance: 1000,
        cash_balance: 1000,
        currency: "USD",
        accountable: account_type.new
      )

      manager = Account::CurrentBalanceManager.new(account)

      assert_equal 0, account.valuations.count

      manager.set_current_balance(1400)

      assert_equal 1, account.valuations.count

      today_valuation = account.entries.valuations.find_by(date: Date.current)

      assert_equal 1400, today_valuation.amount
      assert_equal 1400, account.balance
    end
  end

  # Scope: Depository, CreditCard only (i.e. all-cash accounts)
  #
  # If a user has an opening balance (valuation) for their manual *Depository* or *CreditCard* account and has 1+ transactions, the intent of
  # "updating current balance" typically means that their start balance is incorrect. We follow that user intent
  # by default and find the delta required, and update the opening balance so that the timeline reflects this current balance
  #
  # The purpose of this is so we're not cluttering up their timeline with "balance reconciliations" that reset the balance
  # on the current date. Our goal is to keep the timeline with as few "Valuations" as possible.
  #
  # If we ever build a UI that gives user options, this test expectation may require some updates, but for now this
  # is the least surprising outcome.
  test "when no reconciliations exist on cash accounts, adjust opening balance with delta until it gets us to the desired balance" do
    account = @family.accounts.create!(
      name: "Test",
      balance: 900, # the balance after opening valuation + transaction have "synced" (1000 - 100 = 900)
      cash_balance: 900,
      currency: "USD",
      accountable: Depository.new
    )

    account.entries.create!(
      date: 1.year.ago.to_date,
      name: "Test opening valuation",
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    account.entries.create!(
      date: 10.days.ago.to_date,
      name: "Test expense transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )

    # What we're asserting here:
    # 1. User creates the account with an opening balance of 1000
    # 2. User creates a transaction of 100, which then reduces the balance to 900 (the current balance value on account above)
    # 3. User requests "current balance update" back to 1000, which was their intention
    # 4. We adjust the opening balance by the delta (100) to 1100, which is the new opening balance, so that the transaction
    #    of 100 reduces it down to 1000, which is the current balance they intended.
    assert_equal 1, account.valuations.count
    assert_equal 1, account.transactions.count

    # No new valuation is appended; we're just adjusting the opening valuation anchor
    assert_no_difference "account.entries.count" do
      manager = Account::CurrentBalanceManager.new(account)
      manager.set_current_balance(1000)
    end

    opening_valuation = account.valuations.find_by(kind: "opening_anchor")

    assert_equal 1100, opening_valuation.entry.amount
    assert_equal 1000, account.balance
  end

  # (SEE ABOVE TEST FOR MORE DETAILED EXPLANATION)
  # Same assertions as the test above, but Credit Card accounts are liabilities, which means expenses increase balance; not decrease
  test "when no reconciliations exist on credit card accounts, adjust opening balance with delta until it gets us to the desired balance" do
    account = @family.accounts.create!(
      name: "Test",
      balance: 1100, # the balance after opening valuation + transaction have "synced" (1000 + 100 = 1100) (expenses increase balance)
      cash_balance: 1100,
      currency: "USD",
      accountable: CreditCard.new
    )

    account.entries.create!(
      date: 1.year.ago.to_date,
      name: "Test opening valuation",
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    account.entries.create!(
      date: 10.days.ago.to_date,
      name: "Test expense transaction",
      amount: 100,
      currency: "USD",
      entryable: Transaction.new
    )

    assert_equal 1, account.valuations.count
    assert_equal 1, account.transactions.count

    assert_no_difference "account.entries.count" do
      manager = Account::CurrentBalanceManager.new(account)
      manager.set_current_balance(1000)
    end

    opening_valuation = account.valuations.find_by(kind: "opening_anchor")

    assert_equal 900, opening_valuation.entry.amount
    assert_equal 1000, account.balance
  end
end
