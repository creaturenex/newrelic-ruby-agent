# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require 'new_relic/agent/transaction/tracing'
require 'new_relic/agent/cross_app_tracing'

module NewRelic
  module Agent
    #
    # This module contains helper methods to facilitate
    # instrumentation of external requests not directly supported by
    # the Ruby agent. It is intended to be primarily used by authors
    # of 3rd-party instrumentation.
    #
    # @api public
    module External
      extend self

      # This method creates and starts an external request segment using the
      # given library, URI, and procedure. This is used to time external calls
      # made over HTTP.
      #
      # @param [String] library a string of the class name of the library used to
      # make the external call, for example, 'Net::HTTP'.
      #
      # @param [String, URI] uri indicates the URI to which the
      # external request is being made. The URI should begin with the protocol,
      # for example, 'https://github.com'.
      #
      # @param [String] procedure the HTTP method being used for the external
      # request as a string, for example, 'GET'.
      #
      # @api public
      def start_segment(library: nil, uri: nil, procedure: nil)
        raise ArgumentError, 'Argument `library` is required' if library.nil?
        raise ArgumentError, 'Argument `uri` is required' if uri.nil?
        raise ArgumentError, 'Argument `procedure` is required' if procedure.nil?

        ::NewRelic::Agent.record_api_supportability_metric(:start_segment)

        ::NewRelic::Agent::Transaction.start_external_request_segment(
          library: library,
          uri: uri,
          procedure: procedure
        )
      end

      NON_HTTP_CAT_ID_HEADER  = 'NewRelicID'.freeze
      NON_HTTP_CAT_TXN_HEADER = 'NewRelicTransaction'.freeze
      NON_HTTP_CAT_SYNTHETICS_HEADER = 'NewRelicSynthetics'.freeze

      # Process obfuscated +String+ indentifying a calling application and transaction that is also running a
      # New Relic agent and save information in current transaction for inclusion in a trace. The +String+ is
      # generated by +get_request_metadata+ on the calling application.
      #
      # @param request_metadata [String] received obfuscated request metadata
      #
      # @api public
      #
      def process_request_metadata request_metadata
        NewRelic::Agent.record_api_supportability_metric(:process_request_metadata)
        return unless CrossAppTracing.cross_app_enabled?

        state = NewRelic::Agent::TransactionState.tl_get
        if transaction = state.current_transaction
          rmd = ::JSON.parse obfuscator.deobfuscate(request_metadata)

          # handle/check ID
          #
          if id = rmd[NON_HTTP_CAT_ID_HEADER] and CrossAppTracing.trusted_valid_cross_app_id?(id)
            transaction.client_cross_app_id = id

            # handle transaction info
            #
            if txn_info = rmd[NON_HTTP_CAT_TXN_HEADER]
              transaction.referring_transaction_info = txn_info
              CrossAppTracing.assign_intrinsic_transaction_attributes state
            end

            # handle synthetics
            #
            if synth = rmd[NON_HTTP_CAT_SYNTHETICS_HEADER]
              transaction.synthetics_payload = synth
              transaction.raw_synthetics_header = obfuscator.obfuscate ::JSON.dump(synth)
            end

          else
            NewRelic::Agent.logger.error "error processing request metadata: invalid/non-trusted ID: '#{id}'"
          end

          nil
        end
      rescue => e
        NewRelic::Agent.logger.error 'error during process_request_metadata', e
      end

      # Obtain an obfuscated +String+ suitable for delivery across public networks that carries transaction
      # information from this application to a calling application which is also running a New Relic agent.
      # This +String+ can be processed by +process_response_metadata+ on the calling application.
      #
      # @return [String] obfuscated response metadata to send
      #
      # @api public
      #
      def get_response_metadata
        NewRelic::Agent.record_api_supportability_metric(:get_response_metadata)
        return unless CrossAppTracing.cross_app_enabled?

        state = NewRelic::Agent::TransactionState.tl_get
        if transaction = state.current_transaction and transaction.client_cross_app_id

          # must freeze the name since we're responding with it
          #
          transaction.freeze_name_and_execute_if_not_ignored do

            # build response payload
            #
            rmd = {
              NewRelicAppData: [
                NewRelic::Agent.config[:cross_process_id],
                transaction.timings.transaction_name,
                transaction.timings.queue_time_in_seconds.to_f,
                transaction.timings.app_time_in_seconds.to_f,
                -1, # per non-HTTP CAT spec
                transaction.guid
              ]
            }

            # obfuscate the generated response metadata JSON
            #
            obfuscator.obfuscate ::JSON.dump(rmd)

          end
        end
      rescue => e
        NewRelic::Agent.logger.error "error during get_response_metadata", e
      end

      private

      def obfuscator
        CrossAppTracing.obfuscator
      end

    end
  end
end
