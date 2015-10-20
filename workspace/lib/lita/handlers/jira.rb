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

      def jql_search_formatting(message)
        message = message.gsub('&lt;', '<')
                         .gsub('&gt;', '>')
                         .gsub('&amp;', '&')
                         .gsub('-', '\\-')
                         .gsub('?', '\\?')
                         .gsub('[', '\\[')
                         .gsub(']', '\\]')
                         .gsub('(', '\\(')
                         .gsub(')', '\\)')
                         .gsub('*', '\\*')
                         .gsub("'", %q(\\\'))
                         .gsub(/\\/) { '\\\\' }
      end

      # max 256 JIRA summary length
      def jira_summary_formatting(message)
        message = message.gsub('&lt;', '<')
                         .gsub('&gt;', '>')
                         .gsub('&amp;', '&')

        message = message[0..250]
      end

      def jira_description_formatting(message)
        message = message.gsub('&lt;', '<')
                         .gsub('&gt;', '>')
                         .gsub('&amp;', '&')
      end

      def echo(response)
        message_array = response.matches
        message_string = message_array[0].to_s
        message_string = message_string[2..-3]
        message_string.delete! '\\'
        puts message_string

        data = MultiJson.load(message_string)
        text = data['text']
        text = text.gsub('<', '')
                   .gsub('|View on HockeyApp>', '')

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
        reason = attachment_fields[0][4]['value']

        label = version.split(" ")
        location_search = jql_search_formatting(location)
        location_summary = "Fix crash in #{jira_summary_formatting(location)}"
        location_desc = jira_description_formatting(location)
        reason_search = jql_search_formatting(reason)
        reason_desc = jira_description_formatting(reason)

        log.info
        log.info "text               = #{text}"
        log.info "platform           = #{platform}"
        #log.info "attachement_fields = #{attachment_fields}"
        log.info "release_type       = #{release_type}"
        log.info "version            = #{version}"
        log.info "location           = #{location}"
        log.info "location_search    = #{location_search}"
        log.info "location_summary   = #{location_summary}"
        log.info "location_desc      = #{location_desc}"
        log.info "reason             = #{reason}"
        log.info "reason_search      = #{reason_search}"
        log.info "reason_desc        = #{reason_desc}"
        log.info "label              = #{label[0]}"
        log.info

        issues = fetch_issues("summary ~ '#{location_search}' AND description ~ '#{reason_search}' AND status not in (Closed, 'Test Verified')")

        new_issue = create_issue("OD", "#{location_summary}", "#{text}\n\n*Location:* {code}#{location_desc}{code}\n\n*Reason:* {code}#{reason_desc}{code}\n\n*Platform:* #{platform}\n\n*Release Type:* #{release_type}\n\n*Version:* #{version}", "#{label[0]}") unless issues.size > 0
        log.info "#{t('hockeyappissues.new', site: config.site, key: new_issue.key)}" unless issues.size > 0
        return response.reply(t('hockeyappissues.new', site: config.site, key: new_issue.key)) unless issues.size > 0

        log.info duplicate_issue(issues)
        response.reply(duplicate_issue(issues))
        comment(response, issues, text, platform, release_type, version, label[0])
      end

      def comment(response, issues, text, platform, release_type, version, label)
        issues.map { |issue| comment_issue(response, issue, text, platform, release_type, version, label) }
      end

      def comment_issue(response, issue, text, platform, release_type, version, label)
        comment_string = "#{text}\nplatform: #{platform}\nrelease_type: #{release_type}\nversion: #{version}"
        log.info comment_string
        comment = issue.comments.build
        comment.save!(body: comment_string)
        label_issue(issue, label)
        response.reply(t('comment.added', label: label, issue: issue.key))
      end

      def label_issue(issue, label)
        issue.save(update: { labels: [ {add: label} ] })
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
