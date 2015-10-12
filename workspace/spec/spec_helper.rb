require "simplecov"
require "coveralls"
SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter[
  SimpleCov::Formatter::HTMLFormatter,
  Coveralls::SimpleCov::Formatter
]
SimpleCov.start { add_filter "/spec/" }

require "lita-slack"
require 'lita-jira'
require "lita/rspec"
require "pry"

Lita.version_3_compatibility_mode = false

RSpec.configure do |config|
  config.before do
    registry.register_handler(Lita::Handlers::Jira)
    registry.register_handler(Lita::Handlers::JiraUtility)
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
end

def grab_request(result)
  allow(JIRA::Client).to receive(:new) { result }
end
