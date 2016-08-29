module Kafka
  module Protocol
    class LeaveGroupRequest
      def initialize(group_id:, member_id:)
        @group_id = group_id
        @member_id = member_id
      end

      def api_key
        13
      end

      def response_class
        LeaveGroupResponse
      end

      def encode(encoder)
        encoder.write_string(@group_id)
        encoder.write_string(@member_id)
      end
    end
  end
end
