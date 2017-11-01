# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

require 'uri'
require 'cgi'

module TraceView
  ##
  # TraceView::Rack
  #
  # The TraceView::Rack middleware used to sample a subset of incoming
  # requests for instrumentation and reporting.  Tracing context can
  # be received here (via the X-Trace HTTP header) or initiated here
  # based on configured tracing mode.
  #
  # After the rack layer passes on to the following layers (Rails, Sinatra,
  # Padrino, Grape), then the instrumentation downstream will
  # automatically detect whether this is a sampled request or not
  # and act accordingly. (to instrument or not)
  #
  class Rack
    attr_reader :app

    def initialize(app)
      @app = app
    end

    def collect(req, env)
      report_kvs = {}

      begin
        report_kvs[:'HTTP-Host']        = req.host
        report_kvs[:Port]             = req.port
        report_kvs[:Proto]            = req.scheme
        report_kvs[:Method]            = req.request_method
        report_kvs[:AJAX]             = true if req.xhr?
        report_kvs[:ClientIP]         = req.ip

        if TraceView::Config[:rack][:log_args]
          report_kvs[:'Query-String']     = ::CGI.unescape(req.query_string) unless req.query_string.empty?
        end

        # Report any request queue'ing headers.  Report as 'Request-Start' or the summed Queue-Time
        report_kvs[:'Request-Start']     = env['HTTP_X_REQUEST_START']    if env.key?('HTTP_X_REQUEST_START')
        report_kvs[:'Request-Start']     = env['HTTP_X_QUEUE_START']      if env.key?('HTTP_X_QUEUE_START')
        report_kvs[:'Queue-Time']        = env['HTTP_X_QUEUE_TIME']       if env.key?('HTTP_X_QUEUE_TIME')

        report_kvs[:'Forwarded-For']     = env['HTTP_X_FORWARDED_FOR']    if env.key?('HTTP_X_FORWARDED_FOR')
        report_kvs[:'Forwarded-Host']    = env['HTTP_X_FORWARDED_HOST']   if env.key?('HTTP_X_FORWARDED_HOST')
        report_kvs[:'Forwarded-Proto']   = env['HTTP_X_FORWARDED_PROTO']  if env.key?('HTTP_X_FORWARDED_PROTO')
        report_kvs[:'Forwarded-Port']    = env['HTTP_X_FORWARDED_PORT']   if env.key?('HTTP_X_FORWARDED_PORT')

        report_kvs[:'Ruby.TraceView.Version'] = ::TraceView::Version::STRING
        report_kvs[:ProcessID]         = Process.pid
        report_kvs[:ThreadID]          = Thread.current.to_s[/0x\w*/]
      rescue StandardError => e
        # Discard any potential exceptions. Debug log and report whatever we can.
        TraceView.logger.debug "[traceview/debug] Rack KV collection error: #{e.inspect}"
      end
      report_kvs
    end

    def call(env)
      start = Time.now
      status = 500
      req = ::Rack::Request.new(env)

      env['traceview.transaction'] = req.url

      # In the case of nested Ruby apps such as Grape inside of Rails
      # or Grape inside of Grape, each app has it's own instance
      # of rack middleware.  We avoid tracing rack more than once and
      # instead start instrumenting from the first rack pass.

      # If we're already tracing a rack layer, dont't start another one.
      if TraceView.tracing? && TraceView.layer == :rack
        TraceView.logger.debug "[traceview/rack] Rack skipped!"
        return @app.call(env)
      end

      begin
        report_kvs = {}

        if TraceView::Config[:rack][:log_args]
          report_kvs[:URL] = ::CGI.unescape(req.fullpath)
        else
          report_kvs[:URL] = ::CGI.unescape(req.path)
        end

        # Check for and validate X-Trace request header to pick up tracing context
        xtrace = env.is_a?(Hash) ? env['HTTP_X_TRACE'] : nil
        xtrace_header = xtrace if xtrace && TraceView::XTrace.valid?(xtrace)

        # Under JRuby, JTraceView may have already started a trace.  Make note of this
        # if so and don't clear context on log_end (see traceview/api/logging.rb)
        TraceView.has_incoming_context = TraceView.tracing?
        TraceView.has_xtrace_header = xtrace_header
        TraceView.is_continued_trace = TraceView.has_incoming_context || TraceView.has_xtrace_header

        xtrace = TraceView::API.log_start(:rack, xtrace_header, report_kvs)

        # We only trace a subset of requests based off of sample rate so if
        # TraceView::API.log_start really did start a trace, we act accordingly here.
        if TraceView.tracing?
          report_kvs = collect(req, env)

          # We log an info event with the HTTP KVs found in TraceView::Rack.collect
          # This is done here so in the case of stacks that try/catch/abort
          # (looking at you Grape) we're sure the KVs get reported now as
          # this code may not be returned to later.
          TraceView::API.log_info(:rack, report_kvs)

          status, headers, response = @app.call(env)

          xtrace = TraceView::API.log_end(:rack, :Status => status, 'TransactionName' => env['traceview.transaction'])
        else
          status, headers, response = @app.call(env)
        end
        [status, headers, response]
      rescue Exception => e
        if TraceView.tracing?
          TraceView::API.log_exception(:rack, e)
          xtrace = TraceView::API.log_end(:rack, :Status => 500)
        end
        raise
      ensure
        if headers && TraceView::XTrace.valid?(xtrace)
          unless defined?(JRUBY_VERSION) && TraceView.is_continued_trace?
            headers['X-Trace'] = xtrace if headers.is_a?(Hash)
          end
        end
      end
    ensure
      error = status.between?(500,599) ? 1 : 0
      duration =(1000 * 1000 * (Time.now - start)).round(0)
      TraceView::Span.createHttpSpan(env['traceview.transaction'], req.base_url, duration, status, req.request_method, error)
    end
  end
end
