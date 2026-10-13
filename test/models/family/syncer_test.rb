require "test_helper"

class Family::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "only applies active rules during sync" do
    family_sync = syncs(:family)

    # Create an active rule
    active_rule = @family.rules.create!(
      resource_type: "transaction",
      active: true,
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    # Create a disabled rule
    disabled_rule = @family.rules.create!(
      resource_type: "transaction",
      active: false,
      actions: [ Rule::Action.new(action_type: "exclude_transaction") ]
    )

    syncer = Family::Syncer.new(@family)

    # Stub the relation to return our specific instances so expectations work
    @family.rules.stubs(:where).with(active: true).returns([ active_rule ])

    # Expect apply_later to be called only for the active rule
    active_rule.expects(:apply_later).once
    disabled_rule.expects(:apply_later).never

    # Mock the account syncs to avoid side effects
    Account.any_instance.stubs(:sync_later)

    syncer.perform_sync(family_sync)
    syncer.perform_post_sync
  end

  test "syncs manual accounts" do
    family_sync = syncs(:family)
    syncer = Family::Syncer.new(@family)

    Account.any_instance
           .expects(:sync_later)
           .with(parent_sync: family_sync, window_start_date: nil, window_end_date: nil)
           .times(@family.accounts.manual.count)

    syncer.perform_sync(family_sync)
  end
end
