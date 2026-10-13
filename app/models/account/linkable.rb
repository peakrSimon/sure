module Account::Linkable
  extend ActiveSupport::Concern

  # External account providers have been removed: every account is maintained
  # manually. This concern keeps the linked/manual vocabulary that balance,
  # holdings and view code still branch on.
  included do
    scope :linked, -> { none }
  end

  def linked?
    false
  end

  def unlinked?
    true
  end
  alias_method :manual?, :unlinked?

  def provider
    nil
  end

  def provider_name
    nil
  end

  def can_delete_holdings?
    true
  end
end
