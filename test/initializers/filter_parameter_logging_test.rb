require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  setup do
    @filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  test "keeps descriptive codes readable" do
    filtered = @filter.filter(currency_code: "EUR", country_code: "DE", postal_code: "10115")

    assert_equal "EUR", filtered[:currency_code]
    assert_equal "DE", filtered[:country_code]
    assert_equal "10115", filtered[:postal_code]
  end
end
