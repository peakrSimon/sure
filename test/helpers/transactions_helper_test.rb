require "test_helper"
require "ostruct"

class TransactionsHelperTest < ActionView::TestCase
  # build_transaction_extra_details reads `extra` off a Transaction (or anything
  # that responds to :transaction), so a struct is enough to drive it.
  def transaction_with(extra)
    OpenStruct.new(extra: extra)
  end

  test "renders extra metadata as a raw JSON dump" do
    details = build_transaction_extra_details(transaction_with({ "someprovider" => { "a" => 1 } }))

    assert_equal({ "someprovider" => { "a" => 1 } }, JSON.parse(details[:raw]))
  end

  test "returns nil when there is no extra metadata" do
    assert_nil build_transaction_extra_details(transaction_with({}))
  end
end
