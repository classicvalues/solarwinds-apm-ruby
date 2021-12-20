# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

require 'net/http'

if AppOpticsAPM::Config[:nethttp][:enabled]
  module AppOpticsAPM
    module Inst
      module NetHttp
        include AppOpticsAPM::SDK::TraceContextHeaders

        # Net::HTTP.class_eval do
        # def request_with_appoptics(*args, &block)
        def request(*args, &block)
          # If we're not tracing, just do a fast return. Since
          # net/http.request calls itself, only trace
          # once the http session has been started.
          if !AppOpticsAPM.tracing? || !started?
            add_tracecontext_headers(args[0])
            return super
          end

          kvs = {}
          AppOpticsAPM::SDK.trace(:'net-http', kvs: kvs) do
            # Collect KVs to report in the exit event
            if args.respond_to?(:first) && args.first
              req = args.first

              kvs[:Spec] = 'rsc'
              kvs[:IsService] = 1
              kvs[:RemoteURL] = "#{use_ssl? ? 'https' : 'http'}://#{addr_port}"
              kvs[:RemoteURL] << (AppOpticsAPM::Config[:nethttp][:log_args] ? req.path : req.path.split('?').first)
              kvs[:HTTPMethod] = req.method
              kvs[:Backtrace] = AppOpticsAPM::API.backtrace if AppOpticsAPM::Config[:nethttp][:collect_backtraces]
            end

            begin
              add_tracecontext_headers(args[0])
              # The actual net::http call
              resp = super

              kvs[:HTTPStatus] = resp.code

              # If we get a redirect, report the location header
              if ((300..308).to_a.include? resp.code.to_i) && resp.header["Location"]
                kvs[:Location] = resp.header["Location"]
              end

              resp
            end
          end
        end

      end
    end
  end

  Net::HTTP.prepend(AppOpticsAPM::Inst::NetHttp)
  AppOpticsAPM.logger.info '[appoptics_apm/loading] Instrumenting net/http' if AppOpticsAPM::Config[:verbose]
end
