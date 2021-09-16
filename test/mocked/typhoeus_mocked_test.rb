# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

unless defined?(JRUBY_VERSION)
  require 'minitest_helper'
  require 'mocha/minitest'

  class TyphoeusMockedTest < Minitest::Test

    def setup
      AppOpticsAPM::Context.clear

      WebMock.reset!
      WebMock.allow_net_connect!
      WebMock.disable!

      @sample_rate = AppOpticsAPM::Config[:sample_rate]
      @tracing_mode = AppOpticsAPM::Config[:tracing_mode]
      @blacklist = AppOpticsAPM::Config[:blacklist]

      AppOpticsAPM::Config[:sample_rate] = 1000000
      AppOpticsAPM::Config[:tracing_mode] = :enabled
      AppOpticsAPM::Config[:blacklist] = []
    end

    def teardown
      AppOpticsAPM::Config[:sample_rate] = @sample_rate
      AppOpticsAPM::Config[:tracing_mode] = @tracing_mode
      AppOpticsAPM::Config[:blacklist] = @blacklist
    end

    ############# Typhoeus::Request ##############################################

    def test_tracing_sampling
      AppOpticsAPM::API.start_trace('typhoeus_tests') do
        request = Typhoeus::Request.new("http://127.0.0.2:8101/", { :method=>:get })
        request.run

        assert request.options[:headers]['traceparent']
        assert_match /^2B[0-9A-F]*01$/,request.options[:headers]['traceparent']
      end

      refute AppOpticsAPM::Context.isValid
    end

    def test_tracing_not_sampling
      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config[:sample_rate] = 0
        AppOpticsAPM::API.start_trace('typhoeus_tests') do
          request = Typhoeus::Request.new("http://127.0.0.1:8101/", {:method=>:get})
          request.run

          assert request.options[:headers]['traceparent']
          assert_match /^2B[0-9A-F]*00$/, request.options[:headers]['traceparent']
          refute_match /^2B0*$/, request.options[:headers]['traceparent']
        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_no_xtrace
      request = Typhoeus::Request.new("http://127.0.0.1:8101/", {:method=>:get})
      request.run

      refute request.options[:headers]['traceparent']
      refute AppOpticsAPM::Context.isValid
    end

    def test_blacklisted
      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config.blacklist << '127.0.0.1'
        AppOpticsAPM::API.start_trace('typhoeus_tests') do
          request = Typhoeus::Request.new("http://127.0.0.1:8101/", {:method=>:get})
          request.run

          refute request.options[:headers]['traceparent']
        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_not_sampling_blacklisted
      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config[:sample_rate] = 0
        AppOpticsAPM::Config.blacklist << '127.0.0.1'
        AppOpticsAPM::API.start_trace('typhoeus_tests') do
          request = Typhoeus::Request.new("http://127.0.0.1:8101/", {:method=>:get})
          request.run

          refute request.options[:headers]['traceparent']
        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_preserves_custom_headers
      AppOpticsAPM::API.start_trace('typhoeus_tests') do
        request = Typhoeus::Request.new('http://127.0.0.6:8101', headers: { 'Custom' => 'specialvalue' }, :method => :get)
        request.run

        assert request.options[:headers]['Custom']
        assert_match /specialvalue/, request.options[:headers]['Custom']
      end
      refute AppOpticsAPM::Context.isValid
    end


    ############# Typhoeus::Hydra ##############################################

    def test_hydra_tracing_sampling
      AppOpticsAPM::API.start_trace('typhoeus_tests') do
        hydra = Typhoeus::Hydra.hydra
        request_1 = Typhoeus::Request.new("http://127.0.0.2:8101/", {:method=>:get})
        request_2 = Typhoeus::Request.new("http://127.0.0.2:8101/counting_sheep", {:method=>:get})
        hydra.queue(request_1)
        hydra.queue(request_2)
        hydra.run

        assert request_1.options[:headers]['traceparent'], "There is an traceparent header"
        assert_match /^2B[0-9A-F]*01$/, request_1.options[:headers]['traceparent']
        assert request_2.options[:headers]['traceparent'], "There is an traceparent header"
        assert_match /^2B[0-9A-F]*01$/, request_2.options[:headers]['traceparent']
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_hydra_tracing_not_sampling
      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config[:sample_rate] = 0
        AppOpticsAPM::API.start_trace('typhoeus_tests') do
          hydra = Typhoeus::Hydra.hydra
          request_1 = Typhoeus::Request.new("http://127.0.0.2:8101/", {:method=>:get})
          request_2 = Typhoeus::Request.new("http://127.0.0.2:8101/counting_sheep", {:method=>:get})
          hydra.queue(request_1)
          hydra.queue(request_2)
          hydra.run

          assert request_1.options[:headers]['traceparent'], "There is an traceparent header"
          assert_match /^2B[0-9A-F]*00$/, request_1.options[:headers]['traceparent']
          refute_match /^2B0*$/, request_1.options[:headers]['traceparent']
          assert request_2.options[:headers]['traceparent'], "There is an traceparent header"
          assert_match /^2B[0-9A-F]*00$/, request_2.options[:headers]['traceparent']
          refute_match /^2B0*$/, request_2.options[:headers]['traceparent']
        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_hydra_no_xtrace
      hydra = Typhoeus::Hydra.hydra
      request_1 = Typhoeus::Request.new("http://127.0.0.2:8101/", {:method=>:get})
      request_2 = Typhoeus::Request.new("http://127.0.0.2:8101/counting_sheep", {:method=>:get})
      hydra.queue(request_1)
      hydra.queue(request_2)
      hydra.run

      refute request_1.options[:headers]['traceparent'], "There should not be an traceparent header"
      refute request_2.options[:headers]['traceparent'], "There should not be an traceparent header"
      refute AppOpticsAPM::Context.isValid
    end

    def test_hydra_blacklisted
      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config.blacklist << '127.0.0.2'
        AppOpticsAPM::API.start_trace('typhoeus_tests') do
          hydra = Typhoeus::Hydra.hydra
          request_1 = Typhoeus::Request.new("http://127.0.0.2:8101/", {:method=>:get})
          request_2 = Typhoeus::Request.new("http://127.0.0.2:8101/counting_sheep", {:method=>:get})
          hydra.queue(request_1)
          hydra.queue(request_2)
          hydra.run

          refute request_1.options[:headers]['traceparent'], "There should not be an traceparent header"
          refute request_2.options[:headers]['traceparent'], "There should not be an traceparent header"
        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_hydra_not_sampling_blacklisted
      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config[:sample_rate] = 0
        AppOpticsAPM::Config.blacklist << '127.0.0.2'
        AppOpticsAPM::API.start_trace('typhoeus_tests') do
          hydra = Typhoeus::Hydra.hydra
          request_1 = Typhoeus::Request.new("http://127.0.0.2:8101/", {:method=>:get})
          request_2 = Typhoeus::Request.new("http://127.0.0.2:8101/counting_sheep", {:method=>:get})
          hydra.queue(request_1)
          hydra.queue(request_2)
          hydra.run

          refute request_1.options[:headers]['traceparent'], "There should not be an traceparent header"
          refute request_2.options[:headers]['traceparent'], "There should not be an traceparent header"
        end
      end
      refute AppOpticsAPM::Context.isValid
    end


    def test_hydra_preserves_custom_headers
      AppOpticsAPM::API.start_trace('typhoeus_tests') do
        hydra = Typhoeus::Hydra.hydra
        request = Typhoeus::Request.new('http://127.0.0.6:8101', headers: { 'Custom' => 'specialvalue' }, :method => :get)
        hydra.queue(request)
        hydra.run

        assert request.options[:headers]['Custom']
        assert_match /specialvalue/, request.options[:headers]['Custom']
      end
      refute AppOpticsAPM::Context.isValid
    end

  end
end
