require "test_helper"

class AccountsControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "should get index" do
    get accounts_url
    assert_response :success
    assert_select "p.ml-auto.privacy-sensitive"
  end

  test "show filters account activity to uncategorized transactions" do
    uncategorized = create_transaction(account: @account, name: "Uncategorized Filter Target", category: nil)
    categorized = create_transaction(account: @account, name: "Categorized Filter Decoy", category: categories(:food_and_drink))

    get account_url(@account, q: { uncategorized: "1" })

    assert_response :success
    assert_select "input#q_uncategorized[checked]"
    assert_match uncategorized.name, response.body
    assert_no_match categorized.name, response.body
  end

  test "index delegates whole-row account clicks to the account link" do
    get accounts_url

    assert_response :success
    doc = Nokogiri::HTML::Document.parse(response.body)
    row = doc.at_css("turbo-frame##{dom_id(@account)} [data-controller='clickable-row']")
    account_link = row.at_css("a[data-clickable-row-target='link']")

    assert_equal "click->clickable-row#open", row["data-action"]
    assert_equal account_path(@account), account_link["href"]
  end

  # #3630. A provider card is admitted for a member as soon as ONE of its
  # accounts is shared with them, so the card must list only the accounts this
  # viewer may see. The unshared account is renamed to something no other part
  # of the page can print, so its absence proves the card filtered it.

  # The card's other name-bearing lists. The sync summary's detail rows come
  # from the connection's last sync and name the accounts and transactions
  # involved, so they follow the same rule as the account list: shown only to
  # a viewer who can see every account on the connection. Counts stay.

  # The card header names the connected institution when there is only one.
  # That institution is the unshared account's as much as the shared one's,
  # so it follows the same rule as the other names on the card.

  # The SnapTrade card's brokerage line is built from every
  # account on the connection. With one brokerage it prints that brokerage's
  # name, so a member shared only the nameless account would read the other's.

  test "should get show" do
    get account_url(@account)
    assert_response :success
  end

  test "show renders the balance chart as drag-selectable for a custom date range" do
    get account_url(@account)

    assert_response :success
    assert_select "#lineChart[data-time-series-chart-selectable-value='true']"
  end

  test "show honors a custom start_date/end_date range" do
    start_date = 15.days.ago.to_date
    end_date = Date.current

    get account_url(@account), params: { start_date: start_date.to_s, end_date: end_date.to_s }

    assert_response :success
    # If the params were ignored, the user's default preset would render as the
    # checked option instead of the custom row.
    assert_select "a[role='menuitemradio'][aria-checked='true'][href*='period=']", count: 0
    assert_select "a[role='menuitemradio'][aria-checked='true'][href*='start_date=']", count: 1
  end

  test "show renders without missing translations" do
    get account_url(@account)

    assert_response :success
    assert_empty response.body.scan(/translation missing: [\w.]+/).uniq
  end

  test "show avoids N+1 transfer queries across paginated entries" do
    queries = capture_sql_queries { get account_url(@account) }
    assert_response :success

    # Per-row transfer lookups (N+1 pattern) hit transfers with a single id
    # Preloading batches them into IN(...) — assert no single-id lookups remain
    per_row_transfer = queries.count { |q|
      q.match?(/FROM "transfers".*WHERE.*"(inflow|outflow)_transaction_id"/) &&
        !q.include?(" IN (")
    }
    assert_equal 0, per_row_transfer, "N+1 per-row transfer queries detected (#{per_row_transfer})"
  end

  test "show delegates whole-row trade clicks to the drawer link" do
    investment_account = accounts(:investment)
    entry = entries(:trade)

    get account_url(investment_account)

    assert_response :success
    doc = Nokogiri::HTML::Document.parse(response.body)
    row = doc.at_css("turbo-frame##{dom_id(entry.entryable)} [data-controller='clickable-row']")
    drawer_link = row.at_css("a[data-clickable-row-target='link']")

    assert_equal "click->clickable-row#open", row["data-action"]
    assert_equal entry_path(entry), drawer_link["href"]
  end

  test "show avoids N+1 split-parent queries across paginated entries" do
    queries = capture_sql_queries { get account_url(@account) }
    assert_response :success

    # Per-row child-entry existence checks (N+1) hit entries with a single parent_entry_id
    # @split_parent_entry_ids preloads this in one batch IN query
    per_row_split = queries.count { |q|
      q.match?(/FROM "entries".*WHERE.*"parent_entry_id"/) && !q.include?(" IN (")
    }
    assert_equal 0, per_row_split, "N+1 per-row split-parent queries detected (#{per_row_split})"
  end

  test "show groups split transactions into a single split-group row when grouping is enabled" do
    @user.update!(preferences: { "show_split_grouped" => true })
    entry = create_transaction(name: "Grocery Store", amount: 100, account: @account)
    entry.split!([
      { name: "Food", amount: 60 },
      { name: "Household", amount: 40 }
    ])

    get account_url(@account)

    assert_response :success
    assert_select ".split-group", count: 1
    assert_select ".split-group" do
      assert_select "p", text: "Food", count: 0
    end
  end

  test "show renders split children as flat rows when grouping is disabled" do
    @user.update!(preferences: { "show_split_grouped" => false })
    entry = create_transaction(name: "Grocery Store", amount: 100, account: @account)
    entry.split!([
      { name: "Food", amount: 60 },
      { name: "Household", amount: 40 }
    ])

    get account_url(@account)

    assert_response :success
    assert_select ".split-group", count: 0
  end

  test "show avoids N+1 queries when loading split parents for grouped display" do
    @user.update!(preferences: { "show_split_grouped" => true })
    3.times do |i|
      entry = create_transaction(name: "Grocery Store #{i}", amount: 100, account: @account)
      entry.split!([
        { name: "Food", amount: 60 },
        { name: "Household", amount: 40 }
      ])
    end

    queries = capture_sql_queries { get account_url(@account) }
    assert_response :success

    # @split_parents loads all referenced split-parent entries in a single
    # `WHERE "entries"."id" IN (...)` query — a per-row `"id" = $1` lookup
    # would indicate the batching regressed into N+1.
    per_row_split_parent = queries.count { |q|
      q.match?(/FROM "entries".*WHERE.*"entries"\."id" = \$?\d+/) && !q.include?(" IN (")
    }
    assert_equal 0, per_row_split_parent, "N+1 per-row split-parent lookups detected (#{per_row_split_parent})"
  end

  test "show lazily loads statement tab data unless statements tab is active" do
    AccountStatement::Coverage.expects(:for_year).never
    AccountStatement.expects(:reconciliation_statuses_for).never

    get account_url(@account)

    assert_response :success
    assert_select "select[name='statement_year']", count: 0
    statements_path = account_path(@account, tab: "statements")
    assert_select "turbo-frame[src='#{statements_path}']"
  end

  test "statements tab links escape turbo frame for full-page navigation" do
    # Upload a statement to ensure table rows render
    statement = AccountStatement.create_from_upload!(
      family: @account.family,
      file: uploaded_file(
        filename: "test.pdf",
        content_type: "application/pdf",
        content: "%PDF-1.4 test content"
      ),
      account: @account
    )

    get account_url(@account, tab: "statements")

    assert_response :success

    # Inbox link escapes frame
    assert_select "a[href='#{account_statements_path}'][data-turbo-frame='_top']"

    # Statement filename link escapes frame
    assert_select "a[data-turbo-frame='_top']", text: statement.filename

    # Eye/view icon escapes frame and opens in new tab
    assert_select "a[target='_blank'][data-turbo-frame='_top'][aria-label='#{I18n.t("account_statements.table.view")}']"

    # Edit icon escapes frame
    assert_select "a[href='#{account_statement_path(statement)}'][data-turbo-frame='_top'][aria-label='#{I18n.t("account_statements.table.edit")}']"

    # Unlink button escapes frame
    assert_select "form[action='#{unlink_account_statement_path(statement)}'][data-turbo-frame='_top'] button"
  end

  test "statements tab shows coverage and upload for statement managers with account write access" do
    get account_url(@account, tab: "statements")

    assert_response :success
    assert_select "input[type=file][accept='.pdf,.csv,.xlsx']"
    assert_select "select[name='statement_year']"
    assert_select "p", text: I18n.l(Date.current.prev_month.beginning_of_month, format: "%b %Y")
  end

  test "statements tab lazy frame returns matching frame content" do
    frame_id = dom_id(@account, :statements_tab)

    get account_url(@account, tab: "statements"), headers: { "Turbo-Frame" => frame_id }

    assert_response :success
    assert_select "turbo-frame##{frame_id}", count: 1
    assert_select "select[name='statement_year']"
    assert_select "turbo-frame##{dom_id(@account, :container)}", count: 0
  end

  test "statements tab filters historical coverage by year" do
    account = Account.create!(
      family: @user.family,
      owner: @user,
      name: "Historical Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    statement = AccountStatement.create_from_upload!(
      family: @user.family,
      account: account,
      file: uploaded_file(filename: "historical.csv", content_type: "text/csv")
    )
    statement.update!(period_start_on: Date.new(2024, 2, 1), period_end_on: Date.new(2024, 2, 29))

    travel_to Date.new(2026, 5, 6) do
      get account_url(account, tab: "statements")

      assert_response :success
      assert_select "select[name='statement_year'] option[selected='selected']", text: "2026"
      assert_select "p", text: "May 2026"
      assert_select "p", text: "Not expected"

      get account_url(account, tab: "statements", statement_year: 2024)

      assert_response :success
      assert_select "select[name='statement_year'] option[selected='selected']", text: "2024"
      assert_select "p", text: "Jan 2024"
      assert_select "p", text: "Feb 2024"
      assert_select "p", text: "Covered"
      assert_select "p", text: "Missing"
      assert_select "p", text: "Not expected"
    end
  end

  test "statements tab hides upload for read only account access" do
    sign_in users(:family_member)

    get account_url(accounts(:credit_card), tab: "statements")

    assert_response :success
    assert_select "input[type=file]", count: 0
  end

  test "account activity marks trade amounts as privacy-sensitive" do
    trade_entry = entries(:trade)
    expected_amount = ApplicationController.helpers.format_money(-trade_entry.amount_money)

    get account_url(accounts(:investment))

    assert_response :success
    assert_select "turbo-frame##{dom_id(trade_entry)} p.privacy-sensitive", text: expected_amount, count: 1
  end

  test "account activity keeps excluded entries visible so they can be restored" do
    trade_entry = entries(:trade)
    trade_entry.update!(excluded: true)

    get account_url(accounts(:investment))

    assert_response :success
    assert_select "turbo-frame##{dom_id(trade_entry)}"
  end

  test "renders investment account with gains chart view" do
    get account_url(accounts(:investment), chart_view: "gains")

    assert_response :success
    assert_select "option[value=gains][selected]"
    assert_select "p", text: I18n.t("UI.account.chart.title.total_gains")
  end

  # The chart and the Schedule tab's forecast card read one projection. The
  # chart used to build one and the Schedule partial a second, for the same
  # date, on every render of a loan's page.
  test "a loan account page builds its payoff projection once for the chart and the Schedule tab" do
    loan_account = accounts(:loan)
    projection = loan_account.loan.payoff_projection(as_of: Date.current)
    Loan.any_instance.expects(:payoff_projection).once.returns(projection)

    get account_url(loan_account)

    assert_response :success
    assert_includes response.body, I18n.t("loans.tabs.schedule.forecasted_payoff_date")
  end

  test "remembers selected per_page across account navigation" do
    other_account = accounts(:credit_card)

    get account_url(@account, per_page: 50)
    assert_response :success
    assert_select "select[name='per_page'] option[value='50'][selected]"

    get account_url(other_account)
    assert_response :success
    assert_select "select[name='per_page'] option[value='50'][selected]"
  end

  test "shares remembered per_page with the global transactions page" do
    get transactions_url(per_page: 100)
    assert_response :success

    get account_url(@account)
    assert_response :success
    assert_select "select[name='per_page'] option[value='100'][selected]"
  end

  test "shares account per_page preference with the global transactions page" do
    get account_url(@account, per_page: 50)
    assert_response :success

    get transactions_url
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_select "select[name='per_page'] option[value='50'][selected]"
  end

  test "falls back to default per_page when nothing was stored yet" do
    get account_url(@account)
    assert_response :success
    assert_select "select[name='per_page'] option[value='10'][selected]"
  end

  test "activity pagination keeps activity tab when loaded from holdings tab" do
    investment = accounts(:investment)

    11.times do |i|
      Entry.create!(
        account: investment,
        name: "Test investment activity #{i}",
        date: Date.current - i.days,
        amount: 10 + i,
        currency: investment.currency,
        entryable: Transaction.new
      )
    end

    get account_url(investment, tab: "holdings")

    assert_response :success
    assert_select "a[href*='page=2'][href*='tab=activity']"
    assert_select "a[href*='page=2'][href*='tab=holdings']", count: 0
  end

  test "account activity constrains long category labels before the amount on wide screens" do
    category = categories(:food_and_drink)
    category.update!(name: "Super Long Category Name That Should Stop Before The Amount On Wide Screens Too")

    entry = @account.entries.create!(
      name: "Wide category verification",
      date: Date.current,
      amount: 187.65,
      currency: @account.currency,
      entryable: Transaction.new(category: category)
    )

    get account_url(@account, tab: "activity")

    assert_response :success
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")}"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")}.min-w-0"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")}.overflow-hidden"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")} button.block"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")} button.w-full"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")} button.overflow-hidden"
    assert_select "##{dom_id(entry.entryable, "category_menu_desktop")} [data-testid='category-name']"
    assert_select "div.hidden.md\\:flex.min-w-0"
  end

  test "should sync account" do
    post sync_account_url(@account)
    assert_redirected_to account_url(@account)
  end

  test "should get sparkline" do
    get sparkline_account_url(@account)
    assert_response :success
  end

  test "sparkline renders an empty series without a trend" do
    empty_series = Series.new(
      start_date: 1.day.ago.to_date,
      end_date: Date.current,
      interval: "1 day",
      values: []
    )
    Account.any_instance.expects(:sparkline_series).returns(empty_series)

    get sparkline_account_url(@account)

    assert_response :success
    assert_select "p.font-mono", count: 0
  end

  test "syncing account calls account sync_later" do
    Account.any_instance.expects(:syncing?).returns(false)
    Account.any_instance.expects(:sync_later).once

    post sync_account_url(@account)
    assert_redirected_to account_url(@account)
  end

  test "destroys account" do
    delete account_url(@account)
    assert_redirected_to accounts_path
    assert_enqueued_with job: DestroyJob
    assert_equal "Depository account scheduled for deletion", flash[:notice]
  end

  test "disabling an account keeps it visible on index" do
    @account.disable!

    get accounts_path

    assert_response :success
    assert_includes @response.body, @account.name
  end

  test "toggle_active disables and re-enables an account" do
    patch toggle_active_account_url(@account)
    assert_redirected_to accounts_path
    @account.reload
    assert @account.disabled?

    patch toggle_active_account_url(@account)
    assert_redirected_to accounts_path
    @account.reload
    assert @account.active?
  end

  test "toggle_exclude_from_reports toggles the flag on an account" do
    assert_not @account.exclude_from_reports?

    patch toggle_exclude_from_reports_account_url(@account)
    assert_redirected_to accounts_path
    @account.reload
    assert @account.exclude_from_reports?

    patch toggle_exclude_from_reports_account_url(@account)
    assert_redirected_to accounts_path
    @account.reload
    assert_not @account.exclude_from_reports?
  end

  test "toggle_exclude_from_reports requires write permission" do
    sign_in users(:family_member)

    patch toggle_exclude_from_reports_account_url(accounts(:credit_card))
    assert_redirected_to account_url(accounts(:credit_card))
  end

  test "set_default sets user default account" do
    patch set_default_account_url(@account)
    assert_redirected_to accounts_path
    @user.reload
    assert_equal @account.id, @user.default_account_id
  end

  test "set_default rejects ineligible account type" do
    investment = accounts(:investment)

    patch set_default_account_url(investment)
    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.set_default.depository_only"), flash[:alert]

    @user.reload
    assert_not_equal investment.id, @user.default_account_id
  end

  test "remove_default clears user default account" do
    @user.update!(default_account: @account)

    patch remove_default_account_url(@account)
    assert_redirected_to accounts_path

    @user.reload
    assert_nil @user.default_account_id
  end

  # Regression for #2516: the account sidebar fragment cache renders DS::* view
  # components, which Rails' ERB dependency tracker mis-parses as a bogus "Ds/D"
  # template dependency. With automatic digesting enabled that logged
  # "Couldn't find template for digesting: Ds/D" on every cache miss. The
  # fragment is manually versioned and opts out of digesting via skip_digest.
  test "sidebar fragment cache does not log a bogus template digest error" do
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)

    original_perform_caching = ActionController::Base.perform_caching
    original_view_logger = ActionView::Base.logger
    original_rails_logger = Rails.logger

    ActionController::Base.perform_caching = true
    ActionView::Base.logger = logger
    Rails.logger = logger

    get accounts_path
    assert_response :success
    assert_no_match(/Couldn't find template for digesting/, log.string)
  ensure
    ActionController::Base.perform_caching = original_perform_caching
    ActionView::Base.logger = original_view_logger
    Rails.logger = original_rails_logger
  end
end
