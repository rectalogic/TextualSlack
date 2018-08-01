# TextualSlack

A plugin for [Textual IRC](https://www.codeux.com/textual/) that supports [Slack](https://slack.com/).

## Building

Install [Carthage](https://github.com/Carthage/Carthage#installing-carthage)

To build using Xcode, first run `carthage bootstrap --platform macOS`.
To build a release from a tag, use the `release.sh` script passing the git tag and output build directory.
To build debug libraries `carthage build --configuration Debug --platform macOS`.

## Configuring

Right click on `TextualSlack.bundle` and open with Textual to install.

![Install plugin](/doc/install.png)

Generate a Slack [user token](https://api.slack.com/custom-integrations/legacy-tokens) for your user in the Slack team you want to connect to.

Open Textual preferences and then Textual Slack preferences.

![Textual Slack preferences](/doc/preferences.png)

Click `+` to dd a new account, enter the name (this will be the used as the server name in the Textual sidebar) and enter the Slack user token you generated. Check the box if you want Textual to connect to Slack on startup. Otherwise you can connect on demand using the Server menu.

![Server menu](/doc/menu.png)

## Using

When mentioning a user be sure to prefix their username with `@` so that
is is expanded properly on the Slack side.
