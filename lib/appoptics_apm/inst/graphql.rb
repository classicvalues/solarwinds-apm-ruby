# frozen_string_literal: true

#--
# Copyright (c) 2019 SolarWinds, LLC.
# All rights reserved.
#++

# initial version of this instrumentation:
# https://github.com/librato/api/blob/master/graph/tracing/appoptics.rb
#

# TODO: make sure this stays up to date with
# ____  what is in the graphql gem and vice-versa


if defined?(GraphQL::Tracing) && !(AppOpticsAPM::Config[:graphql][:enabled] == false)
  module GraphQL
    module Tracing
      # AppOpticsTracing in the graphql gem may be a different version than the
      # one defined here, we want to use the newer one
      redefine = true
      this_version = Gem::Version.new('1.1.0')

      if defined?(GraphQL::Tracing::AppOpticsTracing)
        if this_version > GraphQL::Tracing::AppOpticsTracing.version
          send(:remove_const, :AppOpticsTracing)
        else
          redefine = false
        end
      end

      # TODO remove redefine for rebranded nighthawk
      #  there will be no code in the graphql gem for it

      if redefine
        #-----------------------------------------------------------------------------#
        #----- this class is duplicated in the graphql gem ---------------------------#
        #-----------------------------------------------------------------------------#
        class AppOpticsTracing < GraphQL::Tracing::PlatformTracing
          # These GraphQL events will show up as 'graphql.prep' spans
          PREP_KEYS = ['lex', 'parse', 'validate', 'analyze_query', 'analyze_multiplex'].freeze
          EXEC_KEYS = ['execute_multiplex', 'execute_query', 'execute_query_lazy'].freeze

          # During auto-instrumentation this version of AppOpticsTracing is compared
          # with the version provided in the graphql gem, so that the newer
          # version of the class can be used

          # TODO remove for rebranded nighthawk
          def self.version
            Gem::Version.new('1.1.0')
          end

          self.platform_keys = {
            'lex' => 'lex',
            'parse' => 'parse',
            'validate' => 'validate',
            'analyze_query' => 'analyze_query',
            'analyze_multiplex' => 'analyze_multiplex',
            'execute_multiplex' => 'execute_multiplex',
            'execute_query' => 'execute_query',
            'execute_query_lazy' => 'execute_query_lazy'
          }

          def platform_trace(platform_key, _key, data)
            return yield if !defined?(AppOpticsAPM) || gql_config[:enabled] == false

            layer = span_name(platform_key)
            kvs = metadata(data, layer)
            kvs[:Key] = platform_key if (PREP_KEYS + EXEC_KEYS).include?(platform_key)

            transaction_name(kvs[:InboundQuery]) if kvs[:InboundQuery] && layer == 'graphql.execute'

            ::AppOpticsAPM::SDK.trace(layer, kvs: kvs) do
              kvs.clear # we don't have to send them twice
              yield
            end
          end

          def platform_field_key(type, field)
            "graphql.#{type.graphql_name}.#{field.name}"
          end

          def platform_authorized_key(type)
            "graphql.#{type.graphql_name}.authorized"
          end

          def platform_resolve_type_key(type)
            "graphql.#{type.graphql_name}.resolve_type"
          end

          private

          def gql_config
            ::AppOpticsAPM::Config[:graphql] ||= {}
          end

          def transaction_name(query)
            return if gql_config[:transaction_name] == false ||
              ::AppOpticsAPM::SDK.get_transaction_name

            split_query = query.strip.split(/\W+/, 3)
            split_query[0] = 'query' if split_query[0].empty?
            name = "graphql.#{split_query[0..1].join('.')}"

            ::AppOpticsAPM::SDK.set_transaction_name(name)
          end

          def multiplex_transaction_name(names)
            return if gql_config[:transaction_name] == false ||
              ::AppOpticsAPM::SDK.get_transaction_name

            name = "graphql.multiplex.#{names.join('.')}"
            name = "#{name[0..251]}..." if name.length > 254

            ::AppOpticsAPM::SDK.set_transaction_name(name)
          end

          def span_name(key)
            return 'graphql.prep' if PREP_KEYS.include?(key)
            return 'graphql.execute' if EXEC_KEYS.include?(key)

            key[/^graphql\./] ? key : "graphql.#{key}"
          end

          # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          def metadata(data, layer)
            kvs = data.keys.map do |key|
              case key
              when :context
                graphql_context(data[:context], layer)
              when :query
                graphql_query(data[:query])
              when :query_string
                graphql_query_string(data[:query_string])
              when :multiplex
                graphql_multiplex(data[:multiplex])
              else
                [key, data[key]] unless key == :path # we get the path from context
              end
            end

            kvs.compact.flatten.each_slice(2).to_h.merge(Spec: 'graphql')
          end
          # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

          def graphql_context(context, layer)
            context.errors && context.errors.each do |err|
              AppOpticsAPM::API.log_exception(layer, err)
            end

            [[:Path, context.path.join('.')]]
          end

          def graphql_query(query)
            return [] unless query

            query_string = query.query_string
            query_string = remove_comments(query_string) if gql_config[:remove_comments] != false
            query_string = sanitize(query_string) if gql_config[:sanitize_query] != false

            [[:InboundQuery, query_string],
             [:Operation, query.selected_operation_name]]
          end

          def graphql_query_string(query_string)
            query_string = remove_comments(query_string) if gql_config[:remove_comments] != false
            query_string = sanitize(query_string) if gql_config[:sanitize_query] != false

            [:InboundQuery, query_string]
          end

          def graphql_multiplex(data)
            names = data.queries.map(&:operations).map(&:keys).flatten.compact
            multiplex_transaction_name(names) if names.size > 1

            [:Operations, names.join(', ')]
          end

          def sanitize(query)
            return unless query

            # remove arguments
            query.gsub(/"[^"]*"/, '"?"')              # strings
              .gsub(/-?[0-9]*\.?[0-9]+e?[0-9]*/, '?') # ints + floats
              .gsub(/\[[^\]]*\]/, '[?]')              # arrays
          end

          def remove_comments(query)
            return unless query

            query.gsub(/#[^\n\r]*/, '')
          end
        end
        #-----------------------------------------------------------------------------#
      end
    end
  end

  module AppOpticsAPM
    module GraphQLSchemaPrepend
      def use(plugin, **options)
        # super unless GraphQL::Schema.plugins.find { |pl| pl[0].to_s == plugin.to_s }
        super unless self.plugins.find { |pl| pl[0].to_s == plugin.to_s }

        self.plugins
      end

      def inherited(subclass)
        subclass.use(GraphQL::Tracing::AppOpticsTracing)
        super
      end
    end

    # rubocop:disable Style/RedundantSelf
    module GraphQLErrorPrepend
      def initialize(*args)
        super
        bt = AppOpticsAPM::API.backtrace(1)
        set_backtrace(bt) unless self.backtrace
      end
    end
    # rubocop:enable Style/RedundantSelf

    # a different way of autoinstrumenting for graphql 1.7.4 - < 1.8.0
    module GraphQLSchemaPrepend17
      def initialize
        super
        unless tracers.find { |tr| tr.is_a? GraphQL::Tracing::AppOpticsTracing }
          tracer = GraphQL::Tracing::AppOpticsTracing.new
          tracers.push(tracer)
          instrumenters[:field] << tracer
        end
      end
    end
  end

  if Gem.loaded_specs['graphql'] && Gem.loaded_specs['graphql'].version >= Gem::Version.new('1.8.0')
    AppOpticsAPM.logger.info '[appoptics_apm/loading] Instrumenting GraphQL' if AppOpticsAPM::Config[:verbose]
    if defined?(GraphQL::Schema)
      GraphQL::Schema.singleton_class.prepend(AppOpticsAPM::GraphQLSchemaPrepend)
    end

    # rubocop:disable Style/IfUnlessModifier
    if defined?(GraphQL::Error)
      GraphQL::Error.prepend(AppOpticsAPM::GraphQLErrorPrepend)
    end
    # rubocop:enable Style/IfUnlessModifier
  elsif Gem.loaded_specs['graphql'] && Gem.loaded_specs['graphql'].version >= Gem::Version.new('1.7.4')
    AppOpticsAPM.logger.info '[appoptics_apm/loading] Instrumenting GraphQL' if AppOpticsAPM::Config[:verbose]
    if defined?(GraphQL::Schema)
      GraphQL::Schema.prepend(AppOpticsAPM::GraphQLSchemaPrepend17)
    end
  end
end
