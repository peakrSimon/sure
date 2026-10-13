class AccountableSparklinesController < ApplicationController
  def show
    @accountable = Accountable.from_type(params[:accountable_type]&.classify)

    etag_key = cache_key

    # Use HTTP conditional GET so the client receives 304 Not Modified when possible.
    if stale?(etag: etag_key, last_modified: family.latest_sync_completed_at)
      @series = Rails.cache.fetch(etag_key, expires_in: 24.hours) do
        build_series
      end

      render layout: false
    end
  end

  private
    def family
      @family ||= Current.family
    end

    def account_scope
      @account_scope ||= family.accounts.visible.where(accountable_type: @accountable.name)
    end

    def account_ids
      @account_ids ||= account_scope.pluck(:id)
    end

    def build_series
      Balance::ChartSeriesBuilder.new(
        account_ids: account_ids,
        currency: family.currency,
        period: Period.last_30_days,
        favorable_direction: @accountable.favorable_direction,
        interval: "1 day"
      ).balance_series
    end

    def cache_key
      family.build_cache_key("#{@accountable.name}_sparkline_#{Account::Chartable::SPARKLINE_CACHE_VERSION}", invalidate_on_data_updates: true)
    end
end
