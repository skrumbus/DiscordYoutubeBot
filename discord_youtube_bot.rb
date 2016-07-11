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
    @most_recent_messages = load_hash_from_file filename: "most_recent_messages.txt"
    @channel_playlists = load_hash_from_file filename: "channel_playlists.txt"   
    @watching_channels = load_hash_from_file filename: "watching_channels.txt"
    @owner = owner
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
      unless event.text =~ /!watch.*/
        if @watching_channels[event.channel.id.to_s]
          @most_recent_messages[event.channel.id.to_s] = event.message.id
          videos = process_message_for_videos message: event.message
          unless videos.nil?
            add_video_to_playlist video: videos, playlist_id: @channel_playlists[event.channel.id.to_s]
            if videos.size == 1
              if videos[0]['is_duplicate']
                response = "Repost!"
              else
                response = "Added video to the following playlist:"
              end
              event.channel.send_message "#{response} https://www.youtube.com/watch?v=#{videos[0]['video_id']}&list=#{@channel_playlists[event.channel.id.to_s]}"
            elsif videos.size > 1
              event.channel.send_message "Added #{non_duplicates.size} videos to the following playlist: https://www.youtube.com/playlist?list=#{@channel_playlists[event.channel.id.to_s]}"
            end
          end
        end
      end
    end
    server_create do |event|
      initialize_channel channel: event.channel
      event.server.default_channel.send_message "Hi! I'm the Discord YouTube bot. If you want me to start watching one of your channels for youtube videos, type \"#{@prefix}watch {true/false}\". The true/false option tells me whether or not I should check old messages for videos."
    end
    ready do |event|
      unless @owner.nil?
        @owner = user(@owner)
        @owner.pm "Back online!"
      end
      servers.each do |server|
        server = server[1]
        server.text_channels.each do |channel|
          initialize_channel channel: channel
        end
      end
    end
    heartbeat do |event|
      now = Time.now
      if now.hour == 0 and now.minute == 0
        update_playlist_titles
      end
    end
  end
  def configure_commands
    command :stop do |event|
      if (not @owner.nil?) and event.user.id == @owner.id
        save_hash_to_file hash: @most_recent_messages, filename: "most_recent_messages.txt"
        save_hash_to_file hash: @channel_playlists, filename: "channel_playlists.txt"
        save_hash_to_file hash: @watching_channels, filename: "watching_channels.txt"
        @owner.pm "Going down!"
        stop
      end
    end
    command :watch do |event, do_scrape|
      if ((not @owner.nil?) and event.user.id == @owner.id) or event.user.id == event.server.owner.id
        @watching_channels[event.channel.id.to_s] = !@watching_channels[event.channel.id.to_s]
        if @channel_playlists[event.channel.id.to_s].nil?
          initialize_channel channel: event.channel
        end
        if @watching_channels[event.channel.id.to_s]
          event.channel.send_message "Now watching this channel for YouTube videos! Past messages will #{do_scrape ? '' : 'not '}be scanned for videos. All videos will be added to the following playlist: https://youtube.com/playlist?list=#{@channel_playlists[event.channel.id.to_s]}"
          if do_scrape == 'true'
            videos = process_past_messages channel: event.channel
            unless videos.nil?
              add_video_to_playlist video: videos, playlist_id: @channel_playlists[event.channel.id.to_s]
            end
          else
            message = event.channel.history(1)
            @most_recent_messages[event.channel.id.to_s] = message.size == 1 ? message[0].id : nil
          end
          nil
        else
          event.channel.send_message "No longer watching this channel for videos."
        end
      end
    end
  end
  def initialize_channel(channel:)
    if channel.is_a? Array
      channel.each do |c|
        initialize_channel channel: c
      end
    else
      if @watching_channels[channel.id.to_s].nil?
        @watching_channels[channel.id.to_s] = false
      end
      if @channel_playlists[channel.id.to_s].nil?
        @channel_playlists[channel.id.to_s] = @youtube_client.create_playlist(title: "#{channel.server.name}.#{channel.name}", privacy_status: "public").id
      end
      if @most_recent_messages[channel.id.to_s].nil?
        if @watching_channels[channel.id.to_s]
          videos = process_past_messages channel: channel
          unless videos.nil?
            add_video_to_playlist video: videos, playlist_id: @channel_playlists[channel.id.to_s]
          end
        end
      end
    end
    channel
  end
  def load_hash_from_file(filename:)
    hash = {}
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
        is_duplicate = is_duplicate_video? playlist_id: @channel_playlists[message.channel.id.to_s], video_id: video_id
        videos << {'is_duplicate' => is_duplicate, 'video_id' => video_id}
      end
      videos
    else
      Array.new
    end
  end
  def is_duplicate_video?(video_id:, playlist_id:)
    playlist = Yt::Playlist.new id: playlist_id, auth: @youtube_client
    items = playlist.playlist_items
    is_duplicate = false
    unless items.size == 0
      items.each do |item|
        if item.video_id == video_id
          is_duplicate = true
          break
        end
      end
    end
    is_duplicate
  end
  def add_video_to_playlist(video:, playlist_id:)  
    if video.is_a? Array
      video = video.uniq
      video = video.select { |v| not v['is_duplicate'] }
      video.each do |v|
        add_video_to_playlist video: v, playlist_id: playlist_id
      end
    else
      playlist = Yt::Playlist.new id: playlist_id, auth: @youtube_client
      unless video['is_duplicate']
        begin
          playlist.add_video video['video_id']
        rescue => error
          puts "Error adding video #{video['video_id']} to playlist #{playlist_id}."
          puts error.inspect
        end
      end
    end
  end
  def update_playlist_titles
    @channel_playlists.each do |c|
      playlist = Yt::Playlist.new id: c[1], auth: @youtube_client
      chan = channel(c[0])
      playlist.update title: "#{chan.server.name}.#{chan.name}"
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
      puts "Processing past messages from channel '#{channel.name}'"
      messages = channel.history(100, nil, @most_recent_messages[channel.id.to_s])
      videos = Array.new
      count = 0
      if messages.size > 0
        if @most_recent_messages[channel.id.to_s].nil?
          new_most_recent_message = messages[0].id
        else
          new_most_recent_message = messages[-1].id
        end
      else
        new_most_recent_message = nil
      end
      done = false
      while messages.size > 0 and not done do
        messages.each do |message|
          if message.id == @most_recent_messages[channel.id.to_s]
            done = true
            break
          end
          results = process_message_for_videos message: message
          unless results.nil?
            results.each do |result|
              videos << result
            end
          end
          count = count + 1
        end
        puts "  Processed #{count} messages, found #{videos.size} videos..."
        if not done
          if @most_recent_messages[channel.id.to_s].nil? #going backwards
            messages = channel.history(100, messages[-1].id)
          else #going forwards (this is pretty dumb, but oh well)
            messages = channel.history(100, messages[0].id)
          end
        end
      end
      @most_recent_messages[channel.id.to_s] = new_most_recent_message
      videos.reverse
    end
  end
end

if __FILE__ == $0
  if ARGV.size == 6
    bot = DiscordYoutubeBot.new token: ARGV[0], application_id: ARGV[1], client_id: ARGV[2], client_secret: ARGV[3], refresh_token: ARGV[4], owner: ARGV[5], prefix: '!'
    puts bot.invite_url
    bot.run
  else
    puts "Error: Invalid number of arguments. Expected 6, got #{ARGV.size}."
    sleep
  end
end
