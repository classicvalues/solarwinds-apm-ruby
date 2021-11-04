# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

unless defined?(JRUBY_VERSION)
  require 'minitest_helper'
  require 'mocha/minitest'
  require 'net/http'

  require 'rack/test'
  require 'rack/lobster'
  require 'appoptics_apm/inst/rack'

  class NetHTTPMockedTest < Minitest::Test

    include Rack::Test::Methods

    def app
      @app = Rack::Builder.new {
        # use Rack::CommonLogger
        # use Rack::ShowExceptions
        use AppOpticsAPM::Rack
        map "/out" do
          run Proc.new {
            uri = URI('http://127.0.0.1:8101/?q=1')
            Net::HTTP.start(uri.host, uri.port) do |http|
              req = Net::HTTP::Get.new(uri)
              http.request(req)
            [200,
             {"Content-Type" => "text/html"},
             [req['traceparent'], req['tracestate']]]
            end
          }
        end
      }
    end

    # prepend HttpMock to check if appoptics is in the ancestors chain
    # resorting to this solution because a method instrumented by using :prepend
    # can't be mocked with mocha

    def setup
      AppOpticsAPM::Context.clear

      WebMock.reset!
      WebMock.allow_net_connect!
      WebMock.disable!

      @sample_rate = AppOpticsAPM::Config[:sample_rate]
      @tracing_mode = AppOpticsAPM::Config[:tracing_mode]

      AppOpticsAPM::Config[:sample_rate] = 1000000
      AppOpticsAPM::Config[:tracing_mode] = :enabled
    end

    def teardown
      AppOpticsAPM::Config[:sample_rate] = @sample_rate
      AppOpticsAPM::Config[:tracing_mode] = @tracing_mode

      AppOpticsAPM.trace_context = nil
    end

    def test_tracing_sampling
      AppOpticsAPM::API.start_trace('net_http_test') do
        uri = URI('http://127.0.0.1:8101/?q=1')
        Net::HTTP.start(uri.host, uri.port) do |http|
          xt = AppOpticsAPM::Context.toString
          request = Net::HTTP::Get.new(uri)
          refute request['traceparent']

          res = http.request(request)
          # did we instrument?
          assert http.class.ancestors.include?(AppOpticsAPM::Inst::NetHttp)

          # `to_hash` returns a hash with values as arrays
          assert_trace_headers(request.to_hash.inject({}) { |h, (k, v)| h[k] = v[0]; h })
          assert res['x-trace']
          assert AppOpticsAPM::XTrace.sampled?(res['x-trace'])
          refute_equal xt, request['traceparent']
          refute_equal xt, res['x-trace']
        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_tracing_not_sampling
      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config[:sample_rate] = 0
        AppOpticsAPM::API.start_trace('Net::HTTP_test') do
          uri = URI('http://127.0.0.1:8101/?q=1')
          Net::HTTP.start(uri.host, uri.port) do |http|
            xt = AppOpticsAPM::Context.toString
            trace = AppOpticsAPM::TraceContext.ao_to_w3c_trace(xt)
            request = Net::HTTP::Get.new(uri)
            refute request['traceparent']
            res = http.request(request) # Net::HTTPResponse object
            # did we instrument?
            assert http.class.ancestors.include?(AppOpticsAPM::Inst::NetHttp)

            # `to_hash` returns a hash with values as arrays
            assert_trace_headers(request.to_hash.inject({}) { |h, (k, v)| h[k] = v[0]; h })
            assert res['x-trace']
            refute AppOpticsAPM::XTrace.sampled?(res.to_hash['x-trace'])
            assert_equal trace, request['traceparent']
            assert_equal xt, res['x-trace']
          end

        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_no_xtrace
      uri = URI('http://127.0.0.1:8101/?q=1')
      Net::HTTP.start(uri.host, uri.port) do |http|
        request = Net::HTTP::Get.new(uri)
        res = http.request(request) # Net::HTTPResponse object

        assert http.class.ancestors.include?(AppOpticsAPM::Inst::NetHttp)
        refute request['traceparent']
        # the result may have an x-trace from the outbound call and that is ok
      end
    end

    # ========== make sure request headers are preserved =============================
    def test_preserves_custom_headers
      AppOpticsAPM::API.start_trace('Net::HTTP_tests') do
        uri = URI('http://127.0.0.1:8101/?q=1')
        Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new(uri)
          request['Custom'] = 'specialvalue'
          res = http.request(request) # Net::HTTPResponse object
          # did we instrument?
          assert http.class.ancestors.include?(AppOpticsAPM::Inst::NetHttp)

          # `to_hash` returns a hash with values as arrays
          assert_trace_headers(request.to_hash.inject({}) { |h, (k, v)| h[k] = v[0]; h })
          assert res['x-trace']
          assert_equal 'specialvalue', request['Custom']
        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    ##### W3C tracestate propagation

    def test_propagation_simple_trace_state
      task_id = 'a462ade6cfe479081764cc476aa98335'
      trace_id = "00-#{task_id}-cb3468da6f06eefc-01"
      state = 'sw=cb3468da6f06eefc01'
      AppOpticsAPM.trace_context = AppOpticsAPM::TraceContext.new(trace_id, state)

      AppOpticsAPM::API.start_trace('net_http_test', AppOpticsAPM.trace_context.xtrace) do
        uri = URI('http://127.0.0.1:8101/?q=1')
        Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new(uri)
          http.request(request)
          headers = request.each_header.to_h

          assert_trace_headers(headers, true)
          assert_equal task_id, AppOpticsAPM::TraceParent.task_id(headers['traceparent'])
          refute_equal state, headers['tracestate']
        end
      end

      refute AppOpticsAPM::Context.isValid
    end

    def test_propagation_simple_trace_state_not_tracing
      task_id = 'a462ade6cfe479081764cc476aa98335'
      trace_id = "00-#{task_id}-cb3468da6f06eefc-01"
      state = 'sw=cb3468da6f06eefc01'
      AppOpticsAPM.trace_context = AppOpticsAPM::TraceContext.new(trace_id, state)

      uri = URI('http://127.0.0.1:8101/?q=1')
      Net::HTTP.start(uri.host, uri.port) do |http|
        request = Net::HTTP::Get.new(uri)
        http.request(request)
        headers = request.each_header.to_h

        assert_equal trace_id, headers['traceparent']
        assert_equal state, headers['tracestate']
      end

      refute AppOpticsAPM::Context.isValid
    end

    def test_propagation_multimember_trace_state
      task_id = 'a462ade6cfe479081764cc476aa98335'
      trace_id = "00-#{task_id}-cb3468da6f06eefc-01"
      state = 'aa= 1234, sw=cb3468da6f06eefc01,%%cc=%%%45'
      AppOpticsAPM.trace_context = AppOpticsAPM::TraceContext.new(trace_id, state)

      AppOpticsAPM::API.start_trace('net_http_test', AppOpticsAPM.trace_context.xtrace) do
        uri = URI('http://127.0.0.1:8101/?q=1')
        Net::HTTP.start(uri.host, uri.port) do |http|
          request = Net::HTTP::Get.new(uri)
          http.request(request)
          headers = request.each_header.to_h

          assert_trace_headers(headers, true)
          assert_equal task_id, AppOpticsAPM::TraceParent.task_id(headers['traceparent'])
          assert_equal "sw=#{AppOpticsAPM::TraceParent.edge_id_flags(headers['traceparent'])},aa= 1234,%%cc=%%%45",
                       headers['tracestate']
        end
      end

      refute AppOpticsAPM::Context.isValid
    end

  end
end