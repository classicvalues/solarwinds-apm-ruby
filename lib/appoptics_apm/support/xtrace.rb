# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

module AppOpticsAPM
  ##
  # Methods to act on, manipulate or investigate an X-Trace
  # value
  #
  # TODO add unit tests
  class XTrace
    class << self
      ##
      #  AppOpticsAPM::XTrace.valid?
      #
      #  Perform basic validation on a potential X-Trace Id
      #  returns true if it is from a valid context
      #
      def valid?(xtrace)
        # Shouldn't be nil
        return false unless xtrace

        # The X-Trace ID shouldn't be an initialized empty ID
        return false if (xtrace =~ /^2b0000000/i) == 0

        # Valid X-Trace IDs have a length of 60 bytes and start with '2b'
        xtrace.length == 60 && (xtrace =~ /^2b/i) == 0
      rescue StandardError => e
        AppOpticsAPM.logger.debug "[appoptics_apm/xtrace] #{e.message}"
        AppOpticsAPM.logger.debug e.backtrace
        false
      end

      def sampled?(xtrace)
        valid?(xtrace) && xtrace[59].to_i & 1 == 1
      end

      def ok?(xtrace)
        # Valid X-Trace IDs have a length of 60 bytes and start with '2b'
        xtrace && xtrace.length == 60 && (xtrace =~ /^2b/i) == 0
      rescue StandardError => e
        AppOpticsAPM.logger.debug "[appoptics_apm/xtrace] #{e.message}"
        AppOpticsAPM.logger.debug e.backtrace
        false
      end

      def set_sampled(xtrace)
        xtrace[59] = (xtrace[59].hex | 1).to_s(16).upcase
        xtrace
      end

      def unset_sampled(xtrace)
        xtrace[59] = (~(~xtrace[59].hex | 1)).to_s(16).upcase
        xtrace
      end

      ##
      # AppOpticsAPM::XTrace.task_id
      #
      # Extract and return the task_id portion of an X-Trace ID
      #
      def task_id(xtrace)
        return nil unless ok?(xtrace)

        xtrace[2..41]
      rescue StandardError => e
        AppOpticsAPM.logger.debug "[appoptics_apm/xtrace] #{e.message}"
        AppOpticsAPM.logger.debug e.backtrace
        return nil
      end

      ##
      # AppOpticsAPM::XTrace.edge_id
      #
      # Extract and return the edge_id portion of an X-Trace ID
      #
      def edge_id(xtrace)
        return nil unless AppOpticsAPM::XTrace.valid?(xtrace)

        xtrace[42..57]
      rescue StandardError => e
        AppOpticsAPM.logger.debug "[appoptics_apm/xtrace] #{e.message}"
        AppOpticsAPM.logger.debug e.backtrace
        return nil
      end

      ##
      # AppOpticsAPM::XTrace.edge_id_flags
      #
      # Extract and return the edge_id and flags of an X-Trace ID
      #
      def edge_id_flags(xtrace)
        return nil unless AppOpticsAPM::XTrace.valid?(xtrace)

        xtrace[42..-1]
      rescue StandardError => e
        AppOpticsAPM.logger.debug "[appoptics_apm/xtrace] #{e.message}"
        AppOpticsAPM.logger.debug e.backtrace
        return nil
      end

      def replace_edge_id(xtrace, edge_id)
        return xtrace unless edge_id.is_a? String
        "#{xtrace[0..41]}#{edge_id.upcase}#{xtrace[-2..-1]}"
      end

      ##
      # continue_service_context
      #
      # In the case of service calls such as external HTTP requests, we
      # pass along X-Trace headers so that request context can be maintained
      # across servers and applications.
      #
      # Remote requests can return a X-Trace header in which case we want
      # to pickup and continue the context in most cases.
      #
      # +start+ is the context just before the outgoing request
      # +finish+ is the context returned to us (as an HTTP response header
      # if that be the case)
      #
      def continue_service_context(start_xtrace, end_xtrace)
        if AppOpticsAPM::XTrace.valid?(end_xtrace) && AppOpticsAPM.tracing?

          # Make sure that we received back a valid X-Trace with the same task_id
          # and the sampling bit is set, otherwise it is a response from a non-sampling service
          if (AppOpticsAPM::XTrace.task_id(start_xtrace) == AppOpticsAPM::XTrace.task_id(end_xtrace)) &&
            AppOpticsAPM::XTrace.sampled?(end_xtrace)
            AppOpticsAPM::Context.fromString(end_xtrace)
          else
            AppOpticsAPM.logger.debug "[XTrace] Sampling flag unset or mismatched start and finish ids:\n#{start_xtrace}\n#{end_xtrace}"
          end
        end
      end
    end
  end
end
