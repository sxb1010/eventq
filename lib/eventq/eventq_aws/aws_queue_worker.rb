# frozen_string_literal: true

module EventQ
  module Amazon
    class QueueWorker
      include EventQ::WorkerId

      APPROXIMATE_RECEIVE_COUNT = 'ApproximateReceiveCount'
      MESSAGE = 'Message'

      attr_accessor :context

      def initialize
        @serialization_provider_manager = EventQ::SerializationProviders::Manager.new
        @signature_provider_manager = EventQ::SignatureProviders::Manager.new
      end



      def pre_process(context, options)
        # don't do anything specific to set up the process before threads are fired off.
      end

      def thread_process_iteration(queue, options, block)
        client = options[:client]

        unless options[:manager]
          manager = EventQ::Amazon::QueueManager.new({ client: client })
        end

        # get the queue
        queue_url = manager.get_queue(queue)

        received = false
        begin
          # request a message from the queue
          response = client.sqs.receive_message(
              {
                  queue_url: queue_url,
                  max_number_of_messages: 1,
                  wait_time_seconds: @queue_poll_wait,
                  attribute_names: [APPROXIMATE_RECEIVE_COUNT]
              })

          # check that a message was received
          begin
            tag_processing_thread
            response.messages.each do |msg|
              received = true
              process_message(msg, client, queue, block)
            end
          ensure
            untag_processing_thread
          end
        rescue => e
          EventQ.log(:error, "[#{self.class}] - An unhandled error occurred. Error: #{e} | Backtrace: #{e.backtrace}")
          call_on_error_block(error: e)
        end

        received
      end

      def stop; end

      def deserialize_message(payload)
        provider = @serialization_provider_manager.get_provider(EventQ::Configuration.serialization_provider)
        provider.deserialize(payload)
      end

      def serialize_message(msg)
        provider = @serialization_provider_manager.get_provider(EventQ::Configuration.serialization_provider)
        provider.serialize(msg)
      end

      def configure(options = {})
        @queue_poll_wait = options[:queue_poll_wait] || 15

        EventQ.logger.info("[#{self.class}] - Configuring. Queue Poll Wait: #{@queue_poll_wait}")
      end

      private

      def process_message(msg, client, queue, block)
        retry_attempts = msg.attributes[APPROXIMATE_RECEIVE_COUNT].to_i - 1
        queue_url = client.sqs_helper.get_queue_url(queue)

        # deserialize the message payload
        payload = JSON.load(msg.body)
        message = deserialize_message(payload[MESSAGE])

        message_args = EventQ::MessageArgs.new(
            type: message.type,
            retry_attempts: retry_attempts,
            context: message.context,
            content_type: message.content_type,
            id: message.id,
            sent: message.created
        )

        EventQ.logger.info("[#{self.class}] - Message received. Retry Attempts: #{retry_attempts}")

        @signature_provider_manager.validate_signature(message: message, queue: queue)

        if(!EventQ::NonceManager.is_allowed?(message.id))
          EventQ.logger.info("[#{self.class}] - Duplicate Message received. Ignoring message.")
          return false
        end

        # begin worker block for queue message
        begin
          block.call(message.content, message_args)

          if message_args.abort == true
            EventQ.logger.info("[#{self.class}] - Message aborted.")
          else
            # accept the message as processed
            client.sqs.delete_message({ queue_url: queue_url, receipt_handle: msg.receipt_handle })
            EventQ.logger.info("[#{self.class}] - Message acknowledged.")
          end

        rescue => e
          EventQ.logger.error("[#{self.class}] - An unhandled error happened while attempting to process a queue message. Error: #{e} | Backtrace: #{e.backtrace}")
          error = true
          context.call_on_error_block(error: e, message: message)
        end

        if message_args.abort || error
          EventQ::NonceManager.failed(message.id)
          reject_message(queue, client, msg, retry_attempts, message_args.abort)
        else
          EventQ::NonceManager.complete(message.id)
        end

        return true
      end

      def reject_message(queue, client, msg, retry_attempts, abort)
        queue_url = client.sqs_helper.get_queue_url(queue)

        # deserialize the message payload
        payload = JSON.load(msg.body)
        message = deserialize_message(payload[MESSAGE])

        if !queue.allow_retry || retry_attempts >= queue.max_retry_attempts
          EventQ.logger.info("[#{self.class}] - Message rejected removing from queue. Message: #{payload[MESSAGE]}")

          # remove the message from the queue so that it does not get retried again
          client.sqs.delete_message({ queue_url: queue_url, receipt_handle: msg.receipt_handle })
          # Preferable way is to use the sqs poller
          # poller.delete_message(msg)

          if retry_attempts >= queue.max_retry_attempts
            EventQ.logger.info("[#{self.class}] - Message retry attempt limit exceeded.")
            context.call_on_retry_exceeded_block(message)
          end
        elsif queue.allow_retry
          retry_attempts += 1

          EventQ.logger.info("[#{self.class}] - Message rejected requesting retry. Attempts: #{retry_attempts}")

          if queue.allow_retry_back_off
            EventQ.logger.debug { "[#{self.class}] - Calculating message back off retry delay. Attempts: #{retry_attempts} * Delay: #{queue.retry_delay}" }
            visibility_timeout = (queue.retry_delay * retry_attempts) / 1000
            if visibility_timeout > (queue.max_retry_delay / 1000)
              EventQ.logger.debug { "[#{self.class}] - Max message back off retry delay reached." }
              visibility_timeout = queue.max_retry_delay / 1000
            end
          else
            EventQ.logger.debug { "[#{self.class}] - Setting fixed retry delay for message." }
            visibility_timeout = queue.retry_delay / 1000
          end

          if visibility_timeout > 43200
            EventQ.logger.debug { "[#{self.class}] - AWS max visibility timeout of 12 hours has been exceeded. Setting message retry delay to 12 hours." }
            visibility_timeout = 43200
          end

          EventQ.logger.debug { "[#{self.class}] - Sending message for retry. Message TTL: #{visibility_timeout}" }
          client.sqs.change_message_visibility({
                                                   queue_url: queue_url, # required
                                                   receipt_handle: msg.receipt_handle, # required
                                                   visibility_timeout: visibility_timeout.to_s, # required
                                               })

          context.call_on_retry_block(message)

        end

      end
    end
  end
end
