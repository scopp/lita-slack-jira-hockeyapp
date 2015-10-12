require "lita"

Lita.load_locales Dir[File.expand_path(
  File.join("..", "..", "locales", "*.yml"), __FILE__
)]

require 'jira'

require 'jirahelper/issue'
require 'jirahelper/misc'
require 'jirahelper/regex'
require 'jirahelper/utility'

require 'lita/handlers/jira_utility'
require "lita/handlers/jira"

require "lita/adapters/slack"

Lita::Handlers::Jira.template_root File.expand_path(
  File.join("..", "..", "templates"),
 __FILE__
)
