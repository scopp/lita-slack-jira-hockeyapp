require 'lita/adapters/slack/message_handler'

# lita-jira plugin
module Lita
  # Because we can.
  module Handlers
    # Main handler
    # rubocop:disable Metrics/ClassLength
    class Jira < Handler
      namespace 'Jira'

      config :username, required: true, type: String
      config :password, required: true, type: String
      config :site, required: true, type: String
      config :context, required: false, type: String, default: ''
      config :format, required: false, type: String, default: 'verbose'
      config :ambient, required: false, types: [TrueClass, FalseClass], default: false
      config :ignore, required: false, type: Array, default: []
      config :rooms, required: false, type: Array

      include ::JiraHelper::Issue
      include ::JiraHelper::Misc
      include ::JiraHelper::Regex
      include ::JiraHelper::Utility

      route(
        /^jira\scomment\son\s#{ISSUE_PATTERN}\s#{COMMENT_PATTERN}$/,
        :comment,
        command: true,
        help: {
          t('help.comment.syntax') => t('help.comment.desc')
        }
      )

      route(
        /^todo\s#{PROJECT_PATTERN}\s#{SUBJECT_PATTERN}(\s#{SUMMARY_PATTERN})?$/,
        :todo,
        command: true,
        help: {
          t('help.todo.syntax') => t('help.todo.desc')
        }
      )

      # Echo everything
      route /(.*)/, :echo, command: false

      # Detect ambient JIRA issues in non-command messages
      #route ISSUE_PATTERN, :ambient, command: false

              def remove_formatting(message)
                # https://api.slack.com/docs/formatting
                message = message.gsub(/
                    <                    # opening angle bracket
                    (?<type>[@#!])?      # link type
                    (?<link>[^>|]+)      # link
                    (?:\|                # start of |label (optional)
                        (?<label>[^>]+)  # label
                    )?                   # end of label
                    >                    # closing angle bracket
                    /ix) do
                  link  = Regexp.last_match[:link]
                  label = Regexp.last_match[:label]

                  case Regexp.last_match[:type]
                    when '@'
                      if label
                        label
                      else
                        user = User.find_by_id(link)
                        if user
                          "@#{user.mention_name}"
                        else
                          "@#{link}"
                        end
                      end

                    when '#'
                      if label
                        label
                      else
                        channel = Lita::Room.find_by_id(link)
                        if channel
                          "\##{channel.name}"
                        else
                          "\##{link}"
                        end
                      end

                    when '!'
                      "@#{link}" if ['channel', 'group', 'everyone'].include? link
                    else
                      link = link.gsub /^mailto:/, ''
                      if label && !(link.include? label)
                        "#{label} (#{link})"
                      else
                        label == nil ? link : label
                      end
                  end
                end
                message.gsub('&lt;', '<')
                       .gsub('&gt;', '>')
                       .gsub('&amp;', '&')
                       .gsub('-', '\\-')
                       .gsub('?', '\\?')
                       .gsub('[', '\\[')
                       .gsub(']', '\\]')
                       .gsub('(', '\\(')
                       .gsub(')', '\\)')
                       .gsub('*', '\\*')
                       .gsub(/\\/) { '\\\\' }
                       .gsub("'", %q(\\\'))
              end

      def echo(response)
        message_array = response.matches
        message_string = message_array[0].to_s
        message_string = message_string[2..-3]
        message_string.delete! '\\'
        puts message_string

        data = MultiJson.load(message_string)
        text = data['text']
        icons = data['icons']
        attachment_fields = nil
        platform = nil
        release_type = nil
        version = nil
        location = nil
        reason = nil

        attachment_fields = Array(data['attachments']).map do |attachment|
          attachment['fields']
        end

        platform = attachment_fields[0][0]['value']
        release_type = attachment_fields[0][1]['value']
        version = attachment_fields[0][2]['value']
        location = attachment_fields[0][3]['value']
        location = remove_formatting(location)
        reason = attachment_fields[0][4]['value']
        reason = remove_formatting(reason)

        log.info
        log.info "text               = #{text}"
        log.info "platform           = #{platform}"
        #log.info "attachement_fields = #{attachment_fields}"
        log.info "release_type       = #{release_type}"
        log.info "version            = #{version}"
        log.info "location           = #{location}"
        log.info "reason             = #{reason}"
        log.info

        issues = fetch_issues("summary ~ '#{location}' AND description ~ '#{reason}' AND status not in (Closed, 'Test Verified')")

        #new_issue = create_issue("OD", "#{location}", "#{reason}") unless issues.size > 0
        log.info "#{t('hockeyappissues.empty')}" unless issues.size > 0
        return response.reply(t('hockeyappissues.empty')) unless issues.size > 0

        log.info duplicate_issue(issues)
        response.reply(duplicate_issue(issues))
        comment(response, issues, text, platform, release_type, version)
      end

      def comment(response, issues, text, platform, release_type, version)
        issues.map { |issue| comment_issue(response, issue, text, platform, release_type, version) }
      end

      def comment_issue(response, issue, text, platform, release_type, version)
        comment_string = "#{text}\nplatform: #{platform}\nrelease_type: #{release_type}\nversion: #{version}"
        log.info comment_string
        comment = issue.comments.build
        comment.save!(body: comment_string)
        response.reply(t('comment.added', issue: issue.key))
      end

      def todo(response)
        issue = create_issue(response.match_data['project'],
                             response.match_data['subject'],
                             response.match_data['summary'])
        return response.reply(t('error.request')) unless issue
        response.reply(t('issue.created', key: issue.key))
      end

      # rubocop:disable Metrics/AbcSize
      def myissues(response)
        return response.reply(t('error.not_identified')) unless user_stored?(response.user)

        begin
          issues = fetch_issues("assignee = '#{get_email(response.user)}' AND status not in (Closed)")
        rescue
          log.error('JIRA HTTPError')
          response.reply(t('error.request'))
          return
        end

        return response.reply(t('myissues.empty')) unless issues.size > 0

        response.reply(format_issues(issues))
      end

      def ambient(response)
        return if invalid_ambient?(response)
        issue = fetch_issue(response.match_data['issue'], false)
        response.reply(format_issue(issue)) if issue
      end

      private

      def invalid_ambient?(response)
        response.message.command? || !config.ambient || ignored?(response.user) || (config.rooms && !config.rooms.include?(response.message.source.room))
      end

      def ignored?(user)
        config.ignore.include?(user.id) || config.ignore.include?(user.mention_name) || config.ignore.include?(user.name)
      end
      # rubocop:enable Metrics/AbcSize
    end
    # rubocop:enable Metrics/ClassLength
    Lita.register_handler(Jira)
  end
end
