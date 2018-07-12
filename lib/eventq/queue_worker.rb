# frozen_string_literal: true

require 'eventq/worker_status'

module EventQ
  class QueueWorker
    attr_accessor :is_running
    attr_reader :worker_status, :worker_adapter

    def initialize
      @worker_status = EventQ::WorkerStatus.new
      @is_running = false
      @last_gc_flush = Time.now
      @gc_flush_interval = 10
    end

    def start(queue, options = {}, &block)
      EventQ.logger.info("[#{self.class}] - Preparing to start listening for messages.")

      # Make sure mandatory options are specified
      mandatory = [:worker_adapter, :client]
      missing = mandatory - options.keys
      raise "[#{self.class}] - Missing options. #{missing} must be specified." unless missing.empty?

      @worker_adapter = options[:worker_adapter]
      worker_adapter.context = self

      raise "[#{self.class}] - Worker is already running." if running?

      configure(queue, options)
      worker_adapter.configure(options)

      queue_name = EventQ.create_queue_name(queue.name)
      EventQ.logger.info("[#{self.class}] - Listening for messages on queue: #{queue_name}}")

      if @fork_count > 0
        @fork_count.times do
          fork do
            start_process(options, queue, block)
          end
        end

        Process.waitall
      else
        start_process(options, queue, block)
      end

      true
    end

    def start_process(options, queue, block)
      %w'INT TERM'.each do |sig|
        Signal.trap(sig) {
          stop
          exit
        }
      end

      @is_running = true
      tracker = track_process(Process.pid)

      # Execute any specific adapter worker logic before the threads are launched.
      # This could range from setting instance variables, extra options, etc.
      worker_adapter.pre_process(self, options)

      if @thread_count > 0
        @thread_count.times do
          thr = Thread.new do
            start_thread(queue, options, block)
          end

          # Allow the thread to kill the parent process if an error occurs
          thr.abort_on_exception = true
          track_thread(tracker, thr)
        end
      else
        start_thread(queue, options, block)
      end

      unless options[:wait] == false
        worker_status.threads.each { |thr| thr.thread.join }
      end
    end

    def start_thread(queue, options, block)
      if worker_adapter.is_a?(EventQ::RabbitMq::QueueWorkerV2)
        worker_adapter.thread_process_iteration(queue, options, block)
      else
        # begin the queue loop for this thread
        while @is_running do
          # has_message_received = thread_process_iteration(client, manager, queue, block)
          has_message_received = worker_adapter.thread_process_iteration(queue, options, block)
          gc_flush

          if has_message_received == false
            EventQ.logger.debug { "[#{self.class}] - No message received." }
            if @sleep > 0
              EventQ.logger.debug { "[#{self.class}] - Sleeping for #{@sleep} seconds" }
              sleep(@sleep)
            end
          end
        end
      end
    rescue Exception => e # rubocop:disable Lint/RescueException
      EventQ.logger.error(e)
      call_on_error_block(error: e, message: e.message)
      raise Exceptions::WorkerThreadError, e.message, e.backtrace
    end

    def stop
      EventQ.logger.info("[#{self.class}] - Stopping.")
      @is_running = false
      worker_adapter.stop
      # worker_status.threads.each { |thr| thr.thread.join }
    end

    def running?
      @is_running
    end

    def deserialize_message(payload)
      provider = @serialization_provider_manager.get_provider(EventQ::Configuration.serialization_provider)
      provider.deserialize(payload)
    end

    def serialize_message(msg)
      provider = @serialization_provider_manager.get_provider(EventQ::Configuration.serialization_provider)
      provider.serialize(msg)
    end

    def gc_flush
      if Time.now - last_gc_flush > @gc_flush_interval
        GC.start
        @last_gc_flush = Time.now
      end
    end

    def last_gc_flush
      @last_gc_flush
    end

    def configure(queue, options = {})
      # default thread count
      @thread_count = 1
      if options.key?(:thread_count)
        @thread_count = options[:thread_count] if options[:thread_count] > 0
      end

      # default sleep time in seconds
      @sleep = 0
      if options.key?(:sleep)
        @sleep = options[:sleep]
      end

      @fork_count = 0
      if options.key?(:fork_count)
        @fork_count = options[:fork_count]
      end

      if options.key?(:gc_flush_interval)
        @gc_flush_interval = options[:gc_flush_interval]
      end

      @queue_poll_wait = 15
      if options.key?(:queue_poll_wait)
        @queue_poll_wait = options[:queue_poll_wait]
      end

      message_list = [
          "Process Count: #{@fork_count}",
          "Thread Count: #{@thread_count}",
          "Interval Sleep: #{@sleep}",
          "GC Flush Interval: #{@gc_flush_interval}",
          "Queue Poll Wait: #{@queue_poll_wait}"
      ]
      EventQ.logger.info("[#{self.class}] - Configuring. #{message_list.join(' | ')}")
    end

    def call_on_error_block(error:, message: nil)
      if @on_error_block
        EventQ.logger.debug { "[#{self.class}] - Executing on_error block." }
        begin
          @on_error_block.call(error, message)
        rescue => e
          EventQ.logger.error("[#{self.class}] - An error occurred executing the on_error block. Error: #{e}")
        end
      else
        EventQ.logger.debug { "[#{self.class}] - No on_error block specified to execute." }
      end
    end

    def call_on_retry_exceeded_block(message)
      if @on_retry_exceeded_block != nil
        EventQ.logger.debug { "[#{self.class}] - Executing on_retry_exceeded block." }
        begin
          @on_retry_exceeded_block.call(message)
        rescue => e
          EventQ.logger.error("[#{self.class}] - An error occurred executing the on_retry_exceeded block. Error: #{e}")
        end
      else
        EventQ.logger.debug { "[#{self.class}] - No on_retry_exceeded block specified." }
      end
    end

    def call_on_retry_block(message)
      if @on_retry_block
        EventQ.logger.debug { "[#{self.class}] - Executing on_retry block." }
        begin
          @on_retry_block.call(message, abort)
        rescue => e
          EventQ.logger.error("[#{self.class}] - An error occurred executing the on_retry block. Error: #{e}")
        end
      else
        EventQ.logger.debug { "[#{self.class}] - No on_retry block specified." }
      end
    end

    private

    def on_retry_exceeded(&block)
      @retry_exceeded_block = block
    end

    def on_retry(&block)
      @on_retry_block = block
      return nil
    end

    def on_error(&block)
      @on_error_block = block
    end

    def track_process(pid)
      tracker = EventQ::WorkerProcess.new(pid)
      worker_status.processes.push(tracker)
      tracker
    end

    def track_thread(process_tracker, thread)
      tracker = EventQ::WorkerThread.new(thread)
      process_tracker.threads.push(tracker)
      tracker
    end
  end
end
