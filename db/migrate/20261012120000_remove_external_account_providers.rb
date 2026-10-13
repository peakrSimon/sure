# frozen_string_literal: true

# Accounts are maintained manually: drop every bank, brokerage, crypto and
# property-valuation integration along with the generic account_providers link.
# holdings.account_provider_id stays (always NULL now) because the holdings
# materializer still distinguishes provider-reported from calculated rows.
class RemoveExternalAccountProviders < ActiveRecord::Migration[8.1]
  PROVIDER_TABLES = %w[
    account_providers
    akahu_accounts akahu_items
    binance_accounts binance_items
    brex_accounts brex_items
    coinbase_accounts coinbase_items
    coinspot_accounts coinspot_items
    coinstats_accounts coinstats_items
    enable_banking_accounts enable_banking_items
    financekit_account_lineages financekit_accounts financekit_balance_observations
    financekit_batches financekit_conflicts financekit_items financekit_transactions
    fio_accounts fio_items
    ibkr_accounts ibkr_items
    indexa_capital_accounts indexa_capital_items
    kraken_accounts kraken_items
    lunchflow_accounts lunchflow_items
    mercury_accounts mercury_items
    monobank_accounts monobank_items
    onchain_wallet_accounts onchain_wallet_items
    plaid_accounts plaid_items
    provider_request_counts
    questrade_accounts questrade_items
    redbark_accounts redbark_items
    simplefin_accounts simplefin_items
    snaptrade_accounts snaptrade_items
    sophtron_accounts sophtron_items
    trade_republic_accounts trade_republic_items
    trading212_accounts trading212_items
    up_accounts up_items
    wise_accounts wise_items
  ].freeze

  def up
    remove_column :accounts, :plaid_account_id, if_exists: true
    remove_column :accounts, :simplefin_account_id, if_exists: true
    remove_column :accounts, :account_providers_count, if_exists: true
    remove_column :accounts, :enable_category_matcher, if_exists: true
    remove_column :debug_log_entries, :account_provider_id, if_exists: true
    remove_column :entries, :plaid_id, if_exists: true

    remove_check_constraint :properties, name: "properties_avm_provider_check", if_exists: true
    remove_index :properties, name: "index_properties_on_avm_provider_sync", if_exists: true
    remove_column :properties, :avm_provider, if_exists: true
    remove_column :properties, :avm_last_synced_on, if_exists: true

    PROVIDER_TABLES.each do |table|
      drop_table table, if_exists: true, force: :cascade
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
