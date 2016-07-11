# Discord Youtube Bot
## Setup
You must first have a working installation of ruby 2.1+. Once that is done, run the following from a terminal:
```sh
gem install discordrb yt
```
And that's it!
## Running
In order to start the bot, you must run the following from a terminal inside this git repository, replacing the bracketed items with their appropriate values:
```sh
ruby discord_youtube_bot.rb {discord_bot_token} {discord_bot_application_id} {google_client_id} {google_client_secret} {google_account_refresh_token} {discord_owner_id}
```
If you don't wanna have to pass all those arguments every time, you can also create a file in the same folder as the script called options.json and populate it as follows, replacing the bracketed items with their appropriate values:
```json
{
  "refresh_token": "{string}",
  "token": "{string}",
  "application_id": {integer},
  "client_id": "{string}",
  "client_secret": "{string}",
  "owner": {integer}
}

```
And that's it!
