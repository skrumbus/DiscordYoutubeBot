require 'rubygems'
require 'discordrb'
class DiscordYoutubeBot < Discordrb::Commands::CommandBot
  require 'yt'
  require 'json'
  def initialize(
      email: nil, password: nil, log_mode: :normal,
      token: nil, application_id: nil,
      type: nil, name: '', fancy_log: false, suppress_ready: false, parse_self: false,
      shard_id: nil, num_shards: nil,
      prefix: nil,
      owner: nil,
      client_id: nil, client_secret: nil, 
      refresh_token: nil,
      do_delete: false)
    super(
      email: email, password: password, log_mode: log_mode,
      token: token, application_id: application_id,
      type: type, name: name, fancy_log: fancy_log, suppress_ready: suppress_ready, parse_self: parse_self,
      shard_id: shard_id, num_shards: num_shards,
      prefix: prefix)
    configure_commands
    configure_events
    configure_youtube client_id: client_id, client_secret: client_secret
    @youtube_client = refresh_token.nil? ? nil : Yt::Account.new(refresh_token: refresh_token)
    @do_delete = do_delete
    @most_recent_messages = load_hash_from_file filename: "most_recent_messages"
    @channel_playlists = load_hash_from_file filename: "channel_playlists"   
    @watching_channels = load_hash_from_file filename: "watching_channels"
    @delete_permission = load_hash_from_file filename: "delete_permission"
    @owner = owner
    @scraping = {}
  end
  def youtube_client
    @youtube_client
  end
  def owner
    @owner
  end
  private
  
  def configure_youtube(client_id:, client_secret:)
    unless client_id.nil? or client_secret.nil?
      Yt.configure do |config|
        config.client_id = client_id
        config.client_secret = client_secret
      end
    end
  end
  def create_youtube_client(refresh_token:)
    client = nil
    unless refresh_token.nil?
      client = Yt::Account.new refresh_token: refresh_token
    end
    client
  end
  def configure_events
    message do |event|
      unless event.text =~ /^#{@prefix}.*/
        while @scraping[event.channel.id.to_s] do
        end
        if @watching_channels[event.channel.id.to_s]
          @most_recent_messages[event.channel.id.to_s] = event.message.id
          videos = process_message_for_videos message: event.message
          unless videos.nil?
            duplicates = add_video_to_playlist video_id: videos, playlist_id: @channel_playlists[event.channel.id.to_s]
            if videos.size == 1
              if duplicates[0]
                response = "Repost!"
              else
                response = "Added video to the following playlist:"
              end
              event.channel.send_message "#{response} https://www.youtube.com/watch?v=#{videos[0]['video_id']}&list=#{@channel_playlists[event.channel.id.to_s]}"
            elsif videos.size > 1
              event.channel.send_message "Added #{videos.size} videos to the following playlist: https://www.youtube.com/playlist?list=#{@channel_playlists[event.channel.id.to_s]}"
            end
          end
        end
      end
    end
    server_create do |event|
      initialize_channel channel: event.channel
      event.server.default_channel.send_message "Hi! I'm the Discord YouTube bot. If you want me to start watching one of your channels for youtube videos, type \"#{@prefix}watch {true/false}\". The true/false option tells me whether or not I should check old messages for videos (this may take a while)."
    end
    ready do |event|
      unless @owner.nil?
        @owner = user(@owner)
        @owner.pm "Back online!"
      end
      servers.each do |server|
        server = server[1]
        server.text_channels.each do |channel|
          initialize_channel channel: channel, do_scrape: true
        end
      end
    end
    ############################I think heartbeat is broken?
    #heartbeat do |event|
    #  now = Time.now
    #  if now.hour == 0 and now.minute == 0
    #    update_playlist_titles
    #    save_hash_to_file hash: @most_recent_messages, filename: "most_recent_messages"
    #    save_hash_to_file hash: @channel_playlists, filename: "channel_playlists"
    #    save_hash_to_file hash: @watching_channels, filename: "watching_channels"
    #  end
    #end
  end
  def configure_commands
    command :stop do |event|
      if (not @owner.nil?) and event.user.id == @owner.id
        save_hash_to_file hash: @most_recent_messages, filename: "most_recent_messages"
        save_hash_to_file hash: @channel_playlists, filename: "channel_playlists"
        save_hash_to_file hash: @watching_channels, filename: "watching_channels"
        save_hash_to_file hash: @delete_permission, filename: "delete_permission"
        @owner.pm "Going down!"
        stop
      end
    end
    command :scrape do |event|
      if @watching_channels[event.channel.id.to_s]
        if ((not @owner.nil?) and event.user.id == @owner.id) or event.user.id == event.server.owner.id
          puts "Scraping all messages in channel for videos..."
          @most_recent_messages[event.channel.id.to_s] = nil
          initialize_channel channel: event.channel, do_scrape: true
          puts "Done! https://youtube.com/playlist?list=#{@channel_playlists[event.channel.id.to_s]}"
        end
      end
    end
    command :watch do |event, do_scrape|
      if ((not @owner.nil?) and event.user.id == @owner.id) or event.user.id == event.server.owner.id
        @watching_channels[event.channel.id.to_s] = !@watching_channels[event.channel.id.to_s]
        do_scrape = do_scrape == 'true'
        if @watching_channels[event.channel.id.to_s]
          event.channel.send_message "Initializing playlist, one moment..."
          initialize_channel channel: event.channel, do_scrape: do_scrape
          event.channel.send_message "Now watching this channel for YouTube videos! Past messages will #{do_scrape ? '' : 'not '}be scanned for videos. All videos will be added to the following playlist: https://youtube.com/playlist?list=#{@channel_playlists[event.channel.id.to_s]}"
          nil
        else
          event.channel.send_message "No longer watching this channel for videos."
        end
      end
    end
    command :delete do |event|
      if @channel_playlists[event.channel.id.to_s].nil?
        event.channel.send_message "No playlist to delete from!"
      elsif @delete_permission[event.channel.id.to_s].include? event.user.id or @owner.id == event.user.id or event.server.owner.id == event.user.id
        videos = process_message_for_videos message: event.message
        if videos.size == 0
          event.channel.send_message "No youtube video found in your command!"
        else
          playlist = Yt::Playlist.new id: @channel_playlists[event.channel.id.to_s], auth: @youtube_client
          videos.each do |v|
            begin
              playlist.delete_playlist_items video_id: v
            rescue => e
              puts "Error deleting #{v} from playlist #{@channel_playlists[event.channel.id.to_s]}."
            end
          end
          event.channel.send_message "Deleted #{videos.size} video(s) from playlist."
        end
      else
        event.channel.send_message "You don't have permission to perform that command!"
      end
    end
  end
  def initialize_channel(channel:, do_scrape: false)
    if channel.is_a? Array
      channel.each do |c|
        initialize_channel channel: c
      end
    else
      if @watching_channels[channel.id.to_s].nil?
        @watching_channels[channel.id.to_s] = false
      elsif @watching_channels[channel.id.to_s]
        if @channel_playlists[channel.id.to_s].nil?
          @channel_playlists[channel.id.to_s] = @youtube_client.create_playlist(title: "#{channel.server.name}.#{channel.name}", privacy_status: "public").id
        end
        if @delete_permission[channel.id.to_s].nil?
          @delete_permission[channel.id.to_s] = Array.new
        end
        if do_scrape
          videos = process_past_messages channel: channel
          unless videos.nil?
            add_video_to_playlist video_id: videos, playlist_id: @channel_playlists[channel.id.to_s]
          end
        else
          message = channel.history(1)
          @most_recent_messages[channel.id.to_s] = message.size == 0 ? nil : message[0].id
        end
      end
    end
    channel
  end
  def load_hash_from_file(filename:)
    hash = {}
    filename = filename + '.json'
    if File.exists? filename
      begin
        hash = JSON.parse(File.open(filename).read())
      rescue JSON::ParserError => e
        hash = {}
      end
    else
      File.open(filename, "w") {}
    end
    hash
  end
  def save_hash_to_file(filename:, hash:)
    filename = filename + '.json'
    File.open(filename, "w") do |file|
      file.write(JSON.pretty_generate hash)
    end
  end
  def process_message_for_videos(message:)
    if message.is_a? Array
      videos = Array.new
      message.each do |m|
        results = process_message_for_video message: m
        unless results.nil?
          results.each do |result|
            videos << result
          end
        end
      end
      videos
    elsif message.text =~ /\b((youtu.be\/)|(v\/)|(\/u\/\w\/)|(embed\/)|(watch\?))\??v?=?([^#\&\?]{11})/
      videos = Array.new
      message.text.scan(/\b((youtu.be\/)|(v\/)|(\/u\/\w\/)|(embed\/)|(watch\?))\??v?=?([^#\&\?]{11})/).each do |match|
        video_id = match[6].chomp
        videos << video_id
      end
      videos
    else
      Array.new
    end
  end
  def is_video_present?(video_id:, playlist_id:)
    playlist = Yt::Playlist.new id: playlist_id, auth: @youtube_client
    items = playlist.playlist_items
    is_present = false
    unless items.size == 0
      items.each do |item|
        if item.video_id == video_id
          is_present = true
          break
        end
      end
    end
    is_present
  end
  def add_video_to_playlist(video_id:, playlist_id:, is_duplicate: nil)  
    if video_id.is_a? Array
      duplicates = Array.new
      video_id = video_id.uniq
      video_id = video_id.select do |v|
        is_duplicate = is_video_present?(playlist_id: playlist_id, video_id: v)
        duplicates << is_duplicate
        not is_duplicate
      end
      video_id.each do |v|
        add_video_to_playlist video_id: v, playlist_id: playlist_id, is_duplicate: false
      end
      duplicates
    else
      if is_duplicate.nil?
        is_duplicate = is_video_present? playlist_id: playlist_id, video_id: video_id
      end
      playlist = Yt::Playlist.new id: playlist_id, auth: @youtube_client
      begin
        playlist.add_video video_id
      rescue => error
        puts "Error adding video #{video_id} to playlist #{playlist_id}."
      end
      is_duplicate
    end
  end
  def update_playlist_titles
    @channel_playlists.each do |c|
      playlist = Yt::Playlist.new id: c[1], auth: @youtube_client
      channel = channel(c[0])
      playlist.update title: "#{chan.server.name}.#{channel.name}"
    end
  end
  def process_past_messages(channel:)
    if channel.is_a? Array
      videos = Array.new
      channel.each do |c|
        videos << process_past_messages(channel: c)
      end
      videos
    else
      @scraping[channel.id.to_s] = true
      puts "Processing past messages from channel '#{channel.name}'"
      messages = channel.history(100, nil, @most_recent_messages[channel.id.to_s])
      is_forwards = !@most_recent_messages[channel.id.to_s].nil?
      videos = Array.new
      count = 0
      if messages.size > 0
        new_most_recent_message = messages[0].id
      else
        new_most_recent_message = @most_recent_messages[channel.id.to_s]
      end
      while messages.size > 0 do
        (is_forwards ? messages.reverse : messages).each do |message|
          unless message.user.id == profile.id or message.text =~ /^#{prefix}.*/
            results = process_message_for_videos message: message
            unless results.nil?
              results.each do |result|
                videos << result
              end
            end
            count = count + 1
          end
        end
        puts "  Processed #{count} messages, found #{videos.size} videos..."
        new_most_recent_message = is_forwards ? messages[0].id : new_most_recent_message
        if is_forwards #going forwards to newest
          messages = channel.history(100, nil, messages[0].id)
        else #going backwards to infinity
          messages = channel.history(100, messages[-1].id)
        end
      end
      @most_recent_messages[channel.id.to_s] = new_most_recent_message
      @scraping[channel.id.to_s] = false
      if not is_forwards
        videos.reverse
      else
        videos
      end
    end
  end
end

if __FILE__ == $0
  if ARGV.size == 6
    bot = DiscordYoutubeBot.new token: ARGV[0], application_id: ARGV[1], client_id: ARGV[2], client_secret: ARGV[3], refresh_token: ARGV[4], owner: ARGV[5], prefix: '!'
    puts bot.invite_url
    bot.run
  elsif ARGV.size == 0
    if File.exists? 'options.json'
      begin
        options = JSON.parse(File.open('options.json').read())
        bot = DiscordYoutubeBot.new(token: options['token'], 
                                    application_id: options['application_id'],
                                    client_id: options['client_id'],
                                    client_secret: options['client_secret'],
                                    refresh_token: options['refresh_token'],
                                    owner: options['owner'],
                                    prefix: '!',
                                    do_delete: true)
        puts bot.invite_url
        bot.run
      rescue JSON::ParserError => e
        puts "Error: options.json is not a valid json file."
        sleep
      end
    else
      puts "Error: no options.json file found."
      sleep
    end
  else
    puts "Error: Invalid number of arguments. Expected 0 or 6, got #{ARGV.size}."
    sleep
  end
end
