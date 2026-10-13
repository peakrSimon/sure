# Finds transactions already recorded on an account, so CSV and statement
# imports can update an existing entry instead of creating a duplicate.
class Account::ProviderImportAdapter
  attr_reader :account

  # @param account [Account] the account every lookup through this adapter targets
  def initialize(account)
    @account = account
  end

  # Finds a potential duplicate transaction from manual entry or CSV import
  # Matches on date, amount, currency, and optionally name
  # Only matches transactions without external_id (manual/CSV imported)
  #
  # @param date [Date, String] Transaction date
  # @param amount [BigDecimal, Numeric] Transaction amount
  # @param currency [String] Currency code
  # @param name [String, nil] Optional transaction name for more accurate matching
  # @param exclude_entry_ids [Set, Array, nil] Entry IDs to exclude from the search (e.g., already claimed entries)
  # @return [Entry, nil] The duplicate entry or nil if not found
  # @param date_window [Integer] days either side of `date` to consider. Defaults
  #   to 0 (exact date). Statement imports pass a small window, because a
  #   statement's posting date routinely differs from the date recorded for the
  #   same transaction.
  # @param include_provider_entries [Boolean] when false (the default) only
  #   entries without an external_id are considered. A statement import passes
  #   true so entries that arrived through another import are matched too.
  def find_duplicate_transaction(date:, amount:, currency:, name: nil, exclude_entry_ids: nil, date_window: 0, include_provider_entries: false)
    # Convert date to Date object if it's a string
    date = Date.parse(date.to_s) unless date.is_a?(Date)

    # Look for entries on the same account with:
    # 1. Same date (or within date_window of it)
    # 2. Same amount (exact match)
    # 3. Same currency
    # 4. No external_id (manual/CSV imported transactions), unless the caller
    #    opted into provider-sourced entries too
    # 5. Entry type is Transaction (not Trade or Valuation)
    # 6. Optionally same name (if name parameter is provided)
    # 7. Not in the excluded IDs list (if provided)
    query = account.entries
                   .where(entryable_type: "Transaction")
                   .where(amount: amount)
                   .where(currency: currency)

    query = if date_window.to_i.zero?
      query.where(date: date)
    else
      query.where(date: (date - date_window.days)..(date + date_window.days))
    end

    query = query.where(external_id: nil) unless include_provider_entries

    # Add name filter if provided
    query = query.where(name: name) if name.present?

    # Exclude already claimed entries if provided
    query = query.where.not(id: exclude_entry_ids) if exclude_entry_ids.present?

    candidates = query.order(created_at: :asc)

    # Exact-date search keeps the original oldest-first behaviour.
    return candidates.first if date_window.to_i.zero?

    # A windowed search prefers the closest date, falling back to oldest-created
    # on a tie. Done in Ruby because the candidate set is already narrowed to one
    # account, one amount and one currency within a few days -- a handful of rows.
    candidates.to_a.min_by { |entry| [ (entry.date - date).abs, entry.created_at ] }
  end
end
