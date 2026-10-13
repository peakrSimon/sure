class Family::FinancialDataReset
  ConfirmationRequiredError = Class.new(StandardError)

  CONFIRMATION_PHRASE = "RESET FINANCIAL DATA"

  COUNT_KEYS = %i[
    account_statements
    family_exports
    imports
    import_sessions
    import_source_mappings
    import_rows
    import_mappings
    accounts
    account_shares
    entries
    transactions
    transfers
    rejected_transfers
    valuations
    trades
    holdings
    balances
    recurring_transactions
    rules
    rule_actions
    rule_conditions
    rule_runs
    budgets
    budget_categories
    categories
    tags
    taggings
    merchants
    family_merchant_associations
    syncs
    active_storage_attachments
  ].freeze
  STATUS_COUNT_KEYS = (COUNT_KEYS - %i[syncs]).freeze

  Result = Struct.new(:user, :family, :dry_run, :before_counts, :deleted_counts, :after_counts, keyword_init: true)

  attr_reader :user, :family

  def initialize(user: nil, family: nil, dry_run: true, confirmed: false)
    if user && family && user.family != family
      raise ArgumentError, "user and family must belong to the same family"
    end

    @user = user
    @family = family || user&.family
    @dry_run = ActiveModel::Type::Boolean.new.cast(dry_run)
    @confirmed = ActiveModel::Type::Boolean.new.cast(confirmed)

    raise ArgumentError, "user or family is required" unless @family
  end

  def call
    before_counts = counts
    if destructive_without_confirmation?
      raise ConfirmationRequiredError, "Pass confirmed: true to Family::FinancialDataReset to delete financial data."
    end

    if dry_run?
      after_counts = before_counts
    else
      blob_ids = []
      ActiveRecord::Base.transaction do
        blob_ids = active_storage_blob_ids
        delete_financial_data!
      end
      purge_unattached_blobs(blob_ids)
      family.reload
      after_counts = counts
    end

    Result.new(
      user: user,
      family: family,
      dry_run: dry_run?,
      before_counts: before_counts,
      deleted_counts: deleted_counts(before_counts, after_counts),
      after_counts: after_counts
    )
  end

  def dry_run?
    @dry_run
  end

  private

    def destructive_without_confirmation?
      !dry_run? && !@confirmed
    end

    def delete_financial_data!
      scope(:syncs).delete_all
      delete_active_storage_attachments!
      scope(:transfers).destroy_all
      scope(:rejected_transfers).destroy_all
      scope(:import_source_mappings).destroy_all
      scope(:import_mappings).destroy_all
      scope(:import_rows).destroy_all
      scope(:rule_runs).destroy_all
      scope(:rule_actions).destroy_all
      scope(:rule_conditions).destroy_all
      scope(:budget_categories).destroy_all
      scope(:taggings).destroy_all
      scope(:family_merchant_associations).delete_all
      scope(:account_statements).destroy_all
      scope(:family_exports).destroy_all
      scope(:imports).destroy_all
      scope(:import_sessions).destroy_all
      scope(:entries).destroy_all
      scope(:holdings).destroy_all
      scope(:balances).destroy_all
      scope(:account_shares).destroy_all
      scope(:recurring_transactions).destroy_all
      scope(:rules).destroy_all
      scope(:budgets).destroy_all
      scope(:categories).destroy_all
      scope(:tags).destroy_all
      scope(:merchants).destroy_all
      scope(:accounts).destroy_all
    end

    def active_storage_blob_ids
      active_storage_attachment_scopes.flat_map do |scope|
        scope.distinct.pluck(:blob_id)
      end.uniq
    end

    def delete_active_storage_attachments!
      active_storage_attachment_scopes.each do |scope|
        scope.delete_all
      end
    end

    def purge_unattached_blobs(blob_ids)
      return if blob_ids.empty?

      ActiveStorage::Blob
        .where(id: blob_ids)
        .left_outer_joins(:attachments)
        .where(active_storage_attachments: { id: nil })
        .find_each(&:purge)
    end

    def counts
      COUNT_KEYS.index_with do |key|
        key == :active_storage_attachments ? active_storage_attachments_count : scope(key).count
      end
    end

    def deleted_counts(before_counts, after_counts)
      COUNT_KEYS.index_with { |key| before_counts.fetch(key, 0) - after_counts.fetch(key, 0) }
    end

    def scope(key)
      scope_relations.fetch(key)
    end

    def scope_relations
      @scope_relations ||= begin
        account_scope = Account.where(family_id: family.id)
        account_ids = account_scope.select(:id)
        import_scope = Import.where(family_id: family.id)
        import_session_scope = ImportSession.where(family_id: family.id)
        import_ids = import_scope.select(:id)
        rule_scope = Rule.where(family_id: family.id)
        rule_ids = rule_scope.select(:id)
        budget_scope = Budget.where(family_id: family.id)
        budget_ids = budget_scope.select(:id)
        transaction_scope = Transaction.joins(:entry).where(entries: { account_id: account_ids })
        transaction_ids = transaction_scope.select(:id)
        tag_scope = Tag.where(family_id: family.id)

        {
          account_statements: AccountStatement.where(family_id: family.id),
          family_exports: FamilyExport.where(family_id: family.id),
          imports: import_scope,
          import_sessions: import_session_scope,
          import_source_mappings: ImportSourceMapping.where(family_id: family.id),
          import_rows: Import::Row.where(import_id: import_ids),
          import_mappings: Import::Mapping.where(import_id: import_ids),
          accounts: account_scope,
          account_shares: AccountShare.where(account_id: account_ids),
          entries: Entry.where(account_id: account_ids),
          transactions: transaction_scope,
          transfers: Transfer.where(inflow_transaction_id: transaction_ids)
                             .or(Transfer.where(outflow_transaction_id: transaction_ids)),
          rejected_transfers: RejectedTransfer.where(inflow_transaction_id: transaction_ids)
                                             .or(RejectedTransfer.where(outflow_transaction_id: transaction_ids)),
          valuations: Valuation.joins(:entry).where(entries: { account_id: account_ids }),
          trades: Trade.joins(:entry).where(entries: { account_id: account_ids }),
          holdings: Holding.where(account_id: account_ids),
          balances: Balance.where(account_id: account_ids),
          recurring_transactions: RecurringTransaction.where(family_id: family.id),
          rules: rule_scope,
          rule_actions: Rule::Action.where(rule_id: rule_ids),
          rule_conditions: Rule::Condition.where(rule_id: rule_ids),
          rule_runs: RuleRun.where(rule_id: rule_ids),
          budgets: budget_scope,
          budget_categories: BudgetCategory.where(budget_id: budget_ids),
          categories: Category.where(family_id: family.id),
          tags: tag_scope,
          taggings: Tagging.where(tag_id: tag_scope.select(:id)),
          merchants: FamilyMerchant.where(family_id: family.id),
          family_merchant_associations: FamilyMerchantAssociation.where(family_id: family.id),
          syncs: Sync.for_family(family)
        }
      end
    end

    def account_ids
      scope(:accounts).select(:id)
    end

    def active_storage_attachments_count
      active_storage_attachment_scopes.sum(&:count)
    end

    def active_storage_attachment_scopes
      [
        attachment_scope(Account, account_ids),
        attachment_scope(AccountStatement, scope(:account_statements).select(:id)),
        attachment_scope(FamilyExport, scope(:family_exports).select(:id)),
        attachment_scope(Import, scope(:imports).select(:id)),
        attachment_scope(Transaction, scope(:transactions).select(:id))
      ]
    end

    def attachment_scope(record_class, record_ids)
      ActiveStorage::Attachment.where(record_type: record_class.name, record_id: record_ids)
    end
end
