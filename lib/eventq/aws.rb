require 'aws-sdk-core'
require 'eventq'

require_relative './eventq_aws/aws_calculate_visibility_timeout'
require_relative './eventq_aws/aws_eventq_client'
require_relative './eventq_aws/sns'
require_relative './eventq_aws/sqs'
require_relative './eventq_aws/aws_queue_client'
require_relative './eventq_aws/aws_queue_manager'
require_relative './eventq_aws/aws_subscription_manager'
require_relative './eventq_aws/aws_status_checker'
require_relative './eventq_aws/aws_queue_worker'

module EventQ
  def self.namespace
    @namespace
  end
  def self.namespace=(value)
    @namespace = value
  end
  def self.create_event_type(event_type)
    if EventQ.namespace == nil
      return event_type
    end
    return "#{EventQ.namespace}-#{event_type}"
  end
  def self.create_queue_name(queue_name)
    if EventQ.namespace == nil
      return queue_name
    end
    return "#{EventQ.namespace}-#{queue_name}"
  end
end

