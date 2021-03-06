require 'lita/adapters/slack/message_handler'

# lita-jira plugin
module Lita
  # Because we can.
  module Handlers
    # Main handler
    # rubocop:disable Metrics/ClassLength
    class Jira < Handler
      namespace 'Jira'

      config :hockeyapp_token, required: true, type: String
      config :username, required: true, type: String
      config :password, required: true, type: String
      config :site, required: true, type: String
      config :affects_versions, required: false, type: String
      config :component, required: false, type: String
      config :release_excludes, required: false, type: String
      config :projects, required: true, type: String
      config :str_excludes, required: false, type: String
      config :context, required: false, type: String, default: ''
      config :format, required: false, type: String, default: 'verbose'
      config :ambient, required: false, types: [TrueClass, FalseClass], default: false
      config :ignore, required: false, type: Array, default: []
      config :rooms, required: false, type: Array

      include ::JiraHelper::Issue
      include ::JiraHelper::Misc

      PROJECT_PATTERN = /(?<project>[a-zA-Z0-9]{1,10})/
      ISSUE_PATTERN   = /(?<issue>#{PROJECT_PATTERN}-[0-9]{1,5}+)/

      route(/.*jira\s#{ISSUE_PATTERN}.*/,
        :details,
        command: false,
        help: {t('help.details.syntax') => t('help.details.desc')}
      )

      # Anything coming from a bot and has data[username] field
      # see message_handler.rb:158
      route(/(.*New Crash Group for.*)/, :create_or_comment, command: false)

      def details(response)
        issue = fetch_issue(response.match_data['issue'])
        return response.reply(t('error.request')) unless issue
        response.reply(format_issue(issue))
       end


      def create_or_comment(response)
        message_array = response.matches
        message_string = message_array[0].to_s
        message_string = message_string[2..-3]
        message_string = message_string.gsub(/\\\\\\"/) { "'" } #change quoted text to use single quotes
        message_string.delete! '\\' # remove all the extra '/' characters
        puts message_string

        data = MultiJson.load(message_string)
        text = data['text']
        text = text.gsub('<', '')
                   .gsub('|View on HockeyApp>', '')

        icons = data['icons']
        affects_version = nil
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

        hockeyapp_url = text.rpartition(' ').last
        projects = eval(config.projects)
        jira_project = projects[text.split(" ")[4].split("-")[0]]
        location_search = jql_search_formatting(location)
        location_summary = jira_summary_formatting("Fix crash in #{location}")
        location_desc = jira_description_formatting(location)
        reason_search = jql_search_formatting(reason)
        reason_desc = jira_description_formatting(reason)

        release = version.split("(")[0].rstrip                        #get "X.X.X.X" part of "X.X.X.X (version)"
        str_array = release.split(".")
        if release.match /^[A-Z]/
          release = "#{str_array[0]}.#{str_array[1]}"                 #only choose "A.X" part of "X.X.X.X"
        else
          begin
            release = "#{jira_project} #{str_array[0]}.#{str_array[1]}.#{str_array[2].chars.first}" #only choose "1.X.X" part of "X.X.X.X"
          rescue
            log.error("Someone is playing with the invalid '#{release}' release build.")
            return response.reply(t('hockeyappissues.invalid_release', release: release))
          end
        end

        # if release is in AFFECTS_VERSIONS array, add it to the JIRA ticket
        unless config.affects_versions.nil?
          config.affects_versions.split(",").each do |ver|
            if ver.include? release
              affects_version = ver
            end
          end
          if affects_version.nil?
            log.error("The '#{release}' release is not defined in my configs.  '#{release}' crashes will not be processed until that is done.")
            return response.reply(t('hockeyappissues.affects_version_undef_bot', release: release))
          end
        end

        # to prevent duplicates of random memory addresses
        # (e.g. "fault addr eee349d0", "fault addr 00w00300")
        unless config.str_excludes.nil?
          config.str_excludes.split(",").each do |str|
            if location_search.include? str
              location_search = location_search.gsub(/#{str}.+/, "#{str}")
            end
            if reason_search.include? str
              reason_search = reason_search.gsub(/#{str}.+/, "#{str}")
            end
          end
        end

        log.info
        log.info "text               = #{text}"
        log.info "hockeyapp_url      = #{hockeyapp_url}"
        log.info "platform           = #{platform}"
        #log.info "attachement_fields = #{attachment_fields}"
        log.info "release_type       = #{release_type}"
        log.info "version            = #{version}"
        log.info "jira_project       = #{jira_project}"
        log.info "location           = #{location}"
        log.info "location_search    = #{location_search}"
        log.info "location_summary   = #{location_summary}"
        log.info "location_desc      = #{location_desc}"
        log.info "reason             = #{reason}"
        log.info "reason_search      = #{reason_search}"
        log.info "reason_desc        = #{reason_desc}"
        log.info "release            = #{release}"
        log.info "affects_version    = #{affects_version}"

        unless config.release_excludes.nil?
          config.release_excludes.split(",").each do |exclude|
            if exclude == release
              return response.reply(t('release.excluded', release: release))
            end
          end
        end

        jql = "project = #{jira_project} AND summary ~ '#{location_search}' AND description ~ 'reason: #{reason_search}' AND status not in (Closed, 'Test Verified')"
        log.info "jql                = #{jql}"
        log.info

        # search for exisiting JIRA tickets based on location and reason
        issues = fetch_issues(jql)

        apprun = get_hockeyapp_crash_apprun(hockeyapp_url)

        # create a new JIRA ticket if no issues are found
        begin
          new_issue = create_issue("#{jira_project}", "#{location_summary}", "#{text}\n\n*Location:* {code}#{location_desc}{code}\n\n*Reason:* {code}#{reason_desc}{code}\n\n*Platform:* #{platform}\n\n*Release Type:* #{release_type}\n\n*Version:* #{version}\n\n*AppRun:* #{apprun}", "#{affects_version}") unless issues.size > 0
        rescue
          log.error("The '#{release}' release is not defined in JIRA.  '#{release}' crashes will not be processed until that is done.")
          return response.reply(t('hockeyappissues.affects_version_undef_jira', release: release))
        end
        hockeyapp_jira_link(new_issue, hockeyapp_url) unless issues.size > 0
        log.info "#{t('hockeyappissues.new', site: config.site, key: new_issue.key)}" unless issues.size > 0
        return response.reply(t('hockeyappissues.new', site: config.site, key: new_issue.key)) unless issues.size > 0

        # comment on all existing tickets if they exist
        log.info duplicate_issue(issues)
        response.reply(duplicate_issue(issues))
        comment_string = "#{text}\nplatform: #{platform}\nrelease_type: #{release_type}\nversion: #{version}\napprun: #{apprun}\nlocation: {noformat}#{location_desc}{noformat}\nreason: {noformat}#{reason_desc}{noformat}"
        comment_issue(response, issues, comment_string, affects_version, hockeyapp_url)
      end

      # exclude special characters that conflict with JQL queries
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
                         .gsub('{', '\\{')
                         .gsub('}', '\\}')
                         .gsub('*', '\\*')
                         .gsub("'", '')
                         .gsub(/\\/) { '\\\\' }

        message = message[0..250]
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

      def comment_issue(response, issues, comment_string, affects_version, hockeyapp_url)
        issues.map { |issue|
          log.info comment_string
          comment = issue.comments.build
          comment.save!(body: comment_string)
          #label_issue(issue, label)
          add_affects_version(issue, affects_version)
          hockeyapp_jira_link(issue, hockeyapp_url)
          response.reply(t('comment.added', affects_version: affects_version, issue: issue.key))
        }
      end

      def label_issue(issue, label)
        issue.save(update: { labels: [ {add: label} ] })
      end

      def add_affects_version(issue, affects_version)
        issue.save(update: { versions: [ {add: {name: affects_version}} ] })
      end

      # get apprun of crash
      def get_hockeyapp_crash_apprun(hockeyapp_url)
        hockeyapp_api_url = get_hockeyapp_api_url(hockeyapp_url)

        http = Curl.get(hockeyapp_api_url) do|http|
          http.headers['X-HockeyAppToken'] = "#{config.hockeyapp_token}"
        end
        data = JSON.parse(http.body_str)
        crash_id = data['crashes'][0]['id']
        hockeyapp_crash_url = "#{hockeyapp_api_url[/(.*?)crash_reasons/m, 1]}crashes/#{crash_id}?format=text"

        log.info "hockeyapp_crash_url: #{hockeyapp_crash_url}"

        http = Curl.get(hockeyapp_crash_url) do|http|
          http.follow_location = true
          http.headers['X-HockeyAppToken'] = "#{config.hockeyapp_token}"
        end

        body_str = http.body_str[/.*({.*)/m, 1]
        apprun = nil
        if body_str.nil?
          apprun = "no apprun found"
          log.error "apprun: no apprun found"
        else
          data = JSON.parse(body_str)
          apprun = data['apprun']
          log.info "apprun: #{apprun}"
        end

        return apprun
      end

      # update hockey crash with JIRA url, status=0=OPEN
      def hockeyapp_jira_link(issue, hockeyapp_url)
        hockeyapp_api_url = get_hockeyapp_api_url(hockeyapp_url)

        #curl -F "status=0" -F "ticket_url=#{site}/browse/#{issue.key}" -H "X-HockeyAppToken: #{hockeyapp_token}" hockeyapp_api_url
        c = Curl::Easy.http_post("#{hockeyapp_api_url}",
            Curl::PostField.content('status', '0'),
            Curl::PostField.content('ticket_url', "#{config.site}/browse/#{issue.key}")) do |curl|
              curl.headers['X-HockeyAppToken'] = "#{config.hockeyapp_token}"
            end
        c.perform
      end

      def get_hockeyapp_api_url(hockeyapp_url)
        hockeyapp_url = hockeyapp_url.gsub('manage', 'api/2')

        http = Curl.get("https://rink.hockeyapp.net/api/2/apps") do|http|
          http.headers['X-HockeyAppToken'] = "#{config.hockeyapp_token}"
        end

        hockapp_url_id = hockeyapp_url[/apps(.*?)crash_reasons/m, 1].gsub('/', '')
        api_url_id = nil

        data = JSON.parse(http.body_str)
        data['apps'].each do |app|
          if app['id'].to_s == hockapp_url_id.to_s
            api_url_id = app['public_identifier']
          end
        end

        hockeyapp_api_url = hockeyapp_url.gsub("#{hockapp_url_id}", "#{api_url_id}")
        log.info "hockeyapp_url: #{hockeyapp_api_url}"

        return hockeyapp_api_url
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
