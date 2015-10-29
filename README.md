# lita-slack-jira-hockeyapp
A Lita plugin to respond to hockeyapp webhook crashes and find duplicates via slack.

### Make sure to setup these configs:
```
export SLACK_TOKEN=<slack token>
export HOCKEYAPP_TOKEN=<hockeyapp token>
export JIRA_SITE=<jira site url>
export JIRA_USERNAME=<jira username>
export JIRA_PASSWORD=<jira password>
export AFFECTS_VERSIONS="1.0.0 (Jun),OD 1.0.1 (July)" <your affects versions in JIRA>
export RELEASE_EXCLUDES="0.0.1,0.0.2" <any releases you want to exlcude>
```
