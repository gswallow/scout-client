module Scout
  class StreamerDaemon < DaemonSpawn::Base

    # this is the public-facing method for starting the streaming daemon
    def self.start_daemon(history_file, streamer_command, hostname)
      streamer_log_file=File.join(File.dirname(history_file),"scout_streamer.log")
      streamer_pid_file=File.join(File.dirname(history_file),"scout_streamer.pid")

      daemon_spawn_options = {:log_file => streamer_log_file,
                              :pid_file => streamer_pid_file,
                              :sync_log => true,
                              :working_dir => File.dirname(history_file)}

      # streamer command might look like: start,A0000000000123,a,b,c,1,3
      tokens = streamer_command.split(",")
      tokens.shift # gets rid of the "start"
      streaming_key = tokens.shift
      p_app_id = tokens.shift
      p_key = tokens.shift
      p_secret = tokens.shift
      plugin_ids = tokens.map(&:to_i)

      # we use STDOUT for the logger because daemon_spawn directs STDOUT to a log file
      streamer_args = [history_file,streaming_key,p_app_id,p_key,p_secret,plugin_ids,hostname,Logger.new(STDOUT)]
      if File.exists?(streamer_pid_file)
        Scout::StreamerDaemon.restart(daemon_spawn_options, streamer_args)
      else
        Scout::StreamerDaemon.start(daemon_spawn_options, streamer_args)
      end
    end

    # this is the public-facing method for stopping the streaming daemon
    def self.stop_daemon(history_file)
      streamer_log_file=File.join(File.dirname(history_file),"scout_streamer.log")
      streamer_pid_file=File.join(File.dirname(history_file),"scout_streamer.pid")

      daemon_spawn_options = {:log_file => streamer_log_file,
                              :pid_file => streamer_pid_file,
                              :sync_log => true,
                              :working_dir => File.dirname(history_file)}

      Scout::StreamerDaemon.stop(daemon_spawn_options, [])
    end


    # this method is called by DaemonSpawn's class start method.
    def start(streamer_args)
      history,streaming_key,p_app_id,p_key,p_secret,plugin_ids,hostname,log = streamer_args
      @scout = Scout::Streamer.new(history, streaming_key, p_app_id, p_key, p_secret, plugin_ids, hostname, log)
    end

    # this method is called by DaemonSpawn's class start method.
    def stop
      Scout::Streamer.continue_streaming = false
    end

  end
end
