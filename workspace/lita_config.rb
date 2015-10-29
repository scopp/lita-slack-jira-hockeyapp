Lita.configure do |config|
  # The name your robot will use.
  config.robot.name = "HockeyBot"

  # The locale code for the language to use.
  # config.robot.locale = :en

  # The severity of messages to log. Options are:
  # :debug, :info, :warn, :error, :fatal
  # Messages at the selected level and above will be logged.
  config.robot.log_level = :info

  config.http.port = 8081

  # An array of user IDs that are considered administrators. These users
  # the ability to add and remove other users from authorization groups.
  # What is considered a user ID will change depending on which adapter you use.
  # config.robot.admins = ["1", "2"]

  # The adapter you want to connect with. Make sure you've added the
  # appropriate gem to the Gemfile.
  # config.robot.adapter = :shell

  ## Example: Set options for the chosen adapter.
  # config.adapter.username = "myname"
  # config.adapter.password = "secret"

  ## Example: Set options for the Redis connection.
  # config.redis.host = "127.0.0.1"
  # config.redis.port = 1234

  ## Example: Set configuration for any loaded handlers. See the handler's
  ## documentation for options.
  # config.handlers.some_handler.some_config_key = "value"

  config.robot.adapter = :slack
  config.adapters.slack.token = ENV['SLACK_TOKEN']

  config.handlers.jira.hockeyapp_token  = ENV['HOCKEYAPP_TOKEN']
  config.handlers.jira.site             = ENV['JIRA_SITE']
  config.handlers.jira.username         = ENV['JIRA_USERNAME']
  config.handlers.jira.password         = ENV['JIRA_PASSWORD']
  #config.handlers.jira.affects_versions = "1.0.0 (Jun),1.0.1 (July)"
  config.handlers.jira.affects_versions = ENV['AFFECTS_VERSIONS']
  #config.handlers.jira.release_excludes = 1.0.0,1.0.1
  config.handlers.jira.release_excludes = ENV['RELEASE_EXCLUDES']
  #config.handlers.jira.str_excludes     = "fault addr ,libmono.,Unknown."
  config.handlers.jira.str_excludes     = ENV['STR_EXCLUDES']
  config.handlers.jira.ambient          = true


end
