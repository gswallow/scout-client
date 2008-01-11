#!/usr/bin/env ruby -wKU

require "net/https"
require "uri"
require "yaml"
require "timeout"

module Scout
  class Server
    URLS = { :plan   => "/clients/CLIENT_KEY/plugins.scout",
             :report => "/clients/CLIENT_KEY/plugins/PLUGIN_ID/reports.scout",
             :error  => "/clients/CLIENT_KEY/plugins/PLUGIN_ID/errors.scout",
             :alert  => "/clients/CLIENT_KEY/plugins/PLUGIN_ID/alerts.scout" }

    def initialize(server, client_key, history_file, logger = nil)
      @server       = server
      @client_key   = client_key
      @history_file = history_file
      @history      = Hash.new
      @logger       = logger
      
      if block_given?
        load_history
        yield self
        save_history
      end
    end
    
    def load_history
      unless File.exist? @history_file
        debug "Creating empty history file..."
        File.open(@history_file, "w") do |file|
          YAML.dump({"last_runs" => Hash.new, "memory" => Hash.new}, file)
        end
        info "History file created."
      end
      debug "Loading history file..."
      @history = File.open(@history_file) { |file| YAML.load(file) }
      info "History file loaded."
    end
    
    def save_history
      debug "Saving history file..."
      File.open(@history_file, "w") { |file| YAML.dump(@history, file) }
      info "History file saved."
    end
    
    def run_plugins_by_plan
      plan do |plugin|
        info "Processing the #{plugin[:name]} plugin:"
        last_run = @history["last_runs"][plugin[:name]]
        memory   = @history["memory"][plugin[:name]]
        run_time = Time.now
        if last_run.nil? or run_time > last_run + plugin[:interval]
          debug "Plugin is past interval and needs to be run.  " +
                "(last run:  #{last_run || 'nil'})"
          debug "Compiling plugin..."
          begin
            eval(plugin[:code])
            info "Plugin compiled."
          rescue Exception
            fatal "Plugin would not compile."
            exit
          end
          debug "Loading plugin..."
          if job = Plugin.last_defined.load( last_run, (memory || Hash.new),
                                             plugin[:options] || Hash.new )
            info "Plugin loaded."
            debug "Running plugin..."
            begin
              data = nil
              Timeout.timeout(5) { data = job.run }
            rescue Timeout::Error
              fatal "Plugin took too long to run."
              exit
            end
            info "Plugin completed its run."
            report(data[:report], plugin[:plugin_id]) if data[:report]
            if data[:alerts] and not data[:alerts].empty?
              data[:alerts].each { |a| alert(a, plugin[:plugin_id]) }
            end
            error(data[:error], plugin[:plugin_id]) if data[:error]
            @history["last_runs"][plugin[:name]] = run_time
            @history["memory"][plugin[:name]]    = data[:memory]
          else
            error({:subject => "Plugin would not load."}, plugin[:plugin_id])
          end
        else
          debug "Plugin does not need to be run at this time.  " +
                "(last run:  #{last_run || 'nil'})"
        end
        info "Plugin #{plugin[:name]} processing complete."
      end
    end
    
    def plan
      url = urlify(:plan)
      info "Loading plan from #{url}..."
      get(url, "Could not retrieve plan from server.") do |res|
        begin
          plugin_execution_plan = Marshal.load(res.body)
          info "Plan loaded.  (#{plugin_execution_plan.size} plugins:  " +
               "#{plugin_execution_plan.map { |p| p[:name] }.join(', ')})"
        rescue TypeError
          fatal "Plan from server was malformed."
          exit
        end
        plugin_execution_plan.each do |plugin|
          begin
            yield plugin if block_given?
          rescue RuntimeError
            error( { :subject => "Exception:  #{$!.message}.",
                     :body    => $!.backtrace },
                   plugin[:plugin_id] )
          end
        end
      end
    end
    alias_method :test, :plan

    def report(data, plugin_id)
      url = urlify(:report, :plugin_id => plugin_id)
      debug "Sending report to #{url} (#{data.inspect})..."
      post url,
           "Unable to send report to server.",
           :report => {:data => data, :plugin_id => plugin_id}
      info "Report sent."
    end

    def alert(data, plugin_id)
      url = urlify(:alert, :plugin_id => plugin_id)
      debug "Sending alert to #{url} (subject: #{data[:subject]})..."
      post url,
           "Unable to send alert to server.",
           :alert => data.merge(:plugin_id => plugin_id)
      info "Alert sent."
    end

    def error(data, plugin_id)
      url = urlify(:error, :plugin_id => plugin_id)
      debug "Sending error to #{url} (subject: #{data[:subject]})..."
      post url,
           "Unable to log error on server.",
            :error => data.merge(:plugin_id => plugin_id)
      info "Error sent."
    end
    
    private

    def urlify(url_name, options = Hash.new)
      URI.join( @server,
                URLS[url_name].
                  gsub(/\bCLIENT_KEY\b/, @client_key).
                  gsub(/\b[A-Z_]+\b/) { |k| options[k.downcase.to_sym] || k } )
    end

    def paramify(params, prefix = nil)
      params.inject(Hash.new) do |all, (key, value)|
        parent = prefix ? "#{prefix}[#{key}]" : String(key)
        if value.is_a? Hash
          all.merge(paramify(value, parent))
        else
          all.merge(parent => String(value))
        end
      end
    end
    
    def post(url, error, params = {}, &response_handler)
      request(url, response_handler, error) do |connection|
        post = Net::HTTP::Post.new(url.path)
        post.set_form_data(paramify(params))
        connection.request(post)
      end
    end

    def get(url, error, params = {}, &response_handler)
      request(url, response_handler, error) do |connection|
        connection.get(url.path)
      end
    end
    
    def request(url, response_handler, error, &connector)
      http             = Net::HTTP.new(url.host, url.port)
      http.use_ssl     = true
      http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      case response    = no_warnings { http.start(&connector) }
      when Net::HTTPSuccess
        response_handler[response] unless response_handler.nil?
      else
        fatal error
        exit
      end
    rescue Timeout::Error
      fatal "Request timed out."
      exit
    rescue Exception
      fatal "An HTTP error occurred:  #{$!.message}"
      exit
    end
    
    def no_warnings
      old_verbose = $VERBOSE
      $VERBOSE    = false
      yield
    ensure
      $VERBOSE = old_verbose
    end
    
    # Forward Logger methods to an active instance, when there is one.
    def method_missing(meth, *args, &block)
      if (Logger::SEV_LABEL - %w[ANY]).include? meth.to_s.upcase
        @logger.send(meth, *args, &block) unless @logger.nil?
      else
        super
      end
    end
  end
end
