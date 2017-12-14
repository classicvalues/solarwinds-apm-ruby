# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

module AppOptics
  module Inst
    #
    # ActionController
    #
    # This modules contains the instrumentation code specific
    # to Rails v5.
    #
    module ActionControllerAPI
      include ::AppOptics::Inst::RailsBase

      def process_action(method_name, *args)
        kvs = {
            :Controller   => self.class.name,
            :Action       => self.action_name
        }
        request.env['appoptics.controller'] = kvs[:Controller]
        request.env['appoptics.action'] = kvs[:Controller]

        return super(method_name, *args) unless AppOptics.tracing?
        begin
          kvs[:Backtrace] = AppOptics::API.backtrace if AppOptics::Config[:action_controller_api][:collect_backtraces]

          AppOptics::API.log_entry('rails-api', kvs)
          super(method_name, *args)

        rescue Exception => e
          AppOptics::API.log_exception(nil, e) if log_rails_error?(e)
          raise
        ensure
          AppOptics::API.log_exit('rails-api')
        end
      end

      #
      # render
      #
      # Our render wrapper that calls 'add_logging', which will log if we are tracing
      #
      def render(*args, &blk)
        trace('actionview') do
          super(*args, &blk)
        end
      end
    end
  end
end
