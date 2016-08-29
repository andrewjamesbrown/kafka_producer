require "openssl"
require "uri"

require "kafka/cluster"
require "kafka/producer"
require "kafka/consumer"
require "kafka/heartbeat"
require "kafka/async_producer"
require "kafka/fetched_message"
require "kafka/fetch_operation"
require "kafka/connection_builder"
require "kafka/instrumenter"

module Kafka
  class Client

    # Initializes a new Kafka client.
    #
    # @param seed_brokers [Array<String>, String] the list of brokers used to initialize
    #   the client. Either an Array of connections, or a comma separated string of connections.
    #   Connections can either be a string of "port:protocol" or a full URI with a scheme.
    #   If there's a scheme it's ignored and only host/port are used.
    #
    # @param client_id [String] the identifier for this application.
    #
    # @param logger [Logger] the logger that should be used by the client.
    #
    # @param connect_timeout [Integer, nil] the timeout setting for connecting
    #   to brokers. See {BrokerPool#initialize}.
    #
    # @param socket_timeout [Integer, nil] the timeout setting for socket
    #   connections. See {BrokerPool#initialize}.
    #
    # @param ssl_ca_cert [String, nil] a PEM encoded CA cert to use with an
    #   SSL connection.
    #
    # @param ssl_client_cert [String, nil] a PEM encoded client cert to use with an
    #   SSL connection. Must be used in combination with ssl_client_cert_key.
    #
    # @param ssl_client_cert_key [String, nil] a PEM encoded client cert key to use with an
    #   SSL connection. Must be used in combination with ssl_client_cert.
    #
    # @return [Client]
    def initialize(seed_brokers:, client_id: "ruby-kafka", logger: nil, connect_timeout: nil, socket_timeout: nil, ssl_ca_cert: nil, ssl_client_cert: nil, ssl_client_cert_key: nil)
      @logger = logger || Logger.new(nil)
      @instrumenter = Instrumenter.new(client_id: client_id)
      @seed_brokers = normalize_seed_brokers(seed_brokers)

      ssl_context = build_ssl_context(ssl_ca_cert, ssl_client_cert, ssl_client_cert_key)

      @connection_builder = ConnectionBuilder.new(
        client_id: client_id,
        connect_timeout: connect_timeout,
        socket_timeout: socket_timeout,
        ssl_context: ssl_context,
        logger: @logger,
        instrumenter: @instrumenter,
      )

      @cluster = initialize_cluster
    end

    # Delivers a single message to the Kafka cluster.
    #
    # **Note:** Only use this API for low-throughput scenarios. If you want to deliver
    # many messages at a high rate, or if you want to configure the way messages are
    # sent, use the {#producer} or {#async_producer} APIs instead.
    #
    # @param value [String, nil] the message value.
    # @param key [String, nil] the message key.
    # @param topic [String] the topic that the message should be written to.
    # @param partition [Integer, nil] the partition that the message should be written
    #   to, or `nil` if either `partition_key` is passed or the partition should be
    #   chosen at random.
    # @param partition_key [String] a value used to deterministically choose a
    #   partition to write to.
    # @return [nil]
    def deliver_message(value, key: nil, topic:, partition: nil, partition_key: nil)
      create_time = Time.now

      message = PendingMessage.new(
        value,
        key,
        topic,
        partition,
        partition_key,
        create_time,
        key.to_s.bytesize + value.to_s.bytesize
      )

      if partition.nil?
        partition_count = @cluster.partitions_for(topic).count
        partition = Partitioner.partition_for_key(partition_count, message)
      end

      buffer = MessageBuffer.new

      buffer.write(
        value: message.value,
        key: message.key,
        topic: message.topic,
        partition: partition,
        create_time: message.create_time,
      )

      @cluster.add_target_topics([topic])

      compressor = Compressor.new(
        instrumenter: @instrumenter,
      )

      operation = ProduceOperation.new(
        cluster: @cluster,
        buffer: buffer,
        required_acks: 1,
        ack_timeout: 10,
        compressor: compressor,
        logger: @logger,
        instrumenter: @instrumenter,
      )

      operation.execute

      unless buffer.empty?
        raise DeliveryFailed
      end
    end

    # Initializes a new Kafka producer.
    #
    # @param ack_timeout [Integer] The number of seconds a broker can wait for
    #   replicas to acknowledge a write before responding with a timeout.
    #
    # @param required_acks [Integer, Symbol] The number of replicas that must acknowledge
    #   a write, or `:all` if all in-sync replicas must acknowledge.
    #
    # @param max_retries [Integer] the number of retries that should be attempted
    #   before giving up sending messages to the cluster. Does not include the
    #   original attempt.
    #
    # @param retry_backoff [Integer] the number of seconds to wait between retries.
    #
    # @param max_buffer_size [Integer] the number of messages allowed in the buffer
    #   before new writes will raise {BufferOverflow} exceptions.
    #
    # @param max_buffer_bytesize [Integer] the maximum size of the buffer in bytes.
    #   attempting to produce messages when the buffer reaches this size will
    #   result in {BufferOverflow} being raised.
    #
    # @param compression_codec [Symbol, nil] the name of the compression codec to
    #   use, or nil if no compression should be performed. Valid codecs: `:snappy`
    #   and `:gzip`.
    #
    # @param compression_threshold [Integer] the number of messages that needs to
    #   be in a message set before it should be compressed. Note that message sets
    #   are per-partition rather than per-topic or per-producer.
    #
    # @return [Kafka::Producer] the Kafka producer.
    def producer(compression_codec: nil, compression_threshold: 1, ack_timeout: 5, required_acks: :all, max_retries: 2, retry_backoff: 1, max_buffer_size: 1000, max_buffer_bytesize: 10_000_000)
      compressor = Compressor.new(
        codec_name: compression_codec,
        threshold: compression_threshold,
        instrumenter: @instrumenter,
      )

      Producer.new(
        cluster: initialize_cluster,
        logger: @logger,
        instrumenter: @instrumenter,
        compressor: compressor,
        ack_timeout: ack_timeout,
        required_acks: required_acks,
        max_retries: max_retries,
        retry_backoff: retry_backoff,
        max_buffer_size: max_buffer_size,
        max_buffer_bytesize: max_buffer_bytesize,
      )
    end

    # Creates a new AsyncProducer instance.
    #
    # All parameters allowed by {#producer} can be passed. In addition to this,
    # a few extra parameters can be passed when creating an async producer.
    #
    # @param max_queue_size [Integer] the maximum number of messages allowed in
    #   the queue.
    # @param delivery_threshold [Integer] if greater than zero, the number of
    #   buffered messages that will automatically trigger a delivery.
    # @param delivery_interval [Integer] if greater than zero, the number of
    #   seconds between automatic message deliveries.
    #
    # @see AsyncProducer
    # @return [AsyncProducer]
    def async_producer(delivery_interval: 0, delivery_threshold: 0, max_queue_size: 1000, **options)
      sync_producer = producer(**options)

      AsyncProducer.new(
        sync_producer: sync_producer,
        delivery_interval: delivery_interval,
        delivery_threshold: delivery_threshold,
        max_queue_size: max_queue_size,
        instrumenter: @instrumenter,
        logger: @logger,
      )
    end

    # Creates a new Kafka consumer.
    #
    # @param group_id [String] the id of the group that the consumer should join.
    # @param session_timeout [Integer] the number of seconds after which, if a client
    #   hasn't contacted the Kafka cluster, it will be kicked out of the group.
    # @param offset_commit_interval [Integer] the interval between offset commits,
    #   in seconds.
    # @param offset_commit_threshold [Integer] the number of messages that can be
    #   processed before their offsets are committed. If zero, offset commits are
    #   not triggered by message processing.
    # @param heartbeat_interval [Integer] the interval between heartbeats; must be less
    #   than the session window.
    # @return [Consumer]
    def consumer(group_id:, session_timeout: 30, offset_commit_interval: 10, offset_commit_threshold: 0, heartbeat_interval: 10)
      cluster = initialize_cluster

      instrumenter = DecoratingInstrumenter.new(@instrumenter, {
        group_id: group_id,
      })

      group = ConsumerGroup.new(
        cluster: cluster,
        logger: @logger,
        group_id: group_id,
        session_timeout: session_timeout,
      )

      offset_manager = OffsetManager.new(
        cluster: cluster,
        group: group,
        logger: @logger,
        commit_interval: offset_commit_interval,
        commit_threshold: offset_commit_threshold,
      )

      heartbeat = Heartbeat.new(
        group: group,
        interval: heartbeat_interval,
      )

      Consumer.new(
        cluster: cluster,
        logger: @logger,
        instrumenter: instrumenter,
        group: group,
        offset_manager: offset_manager,
        session_timeout: session_timeout,
        heartbeat: heartbeat,
      )
    end

    # Fetches a batch of messages from a single partition. Note that it's possible
    # to get back empty batches.
    #
    # The starting point for the fetch can be configured with the `:offset` argument.
    # If you pass a number, the fetch will start at that offset. However, there are
    # two special Symbol values that can be passed instead:
    #
    # * `:earliest` — the first offset in the partition.
    # * `:latest` — the next offset that will be written to, effectively making the
    #   call block until there is a new message in the partition.
    #
    # The Kafka protocol specifies the numeric values of these two options: -2 and -1,
    # respectively. You can also pass in these numbers directly.
    #
    # ## Example
    #
    # When enumerating the messages in a partition, you typically fetch batches
    # sequentially.
    #
    #     offset = :earliest
    #
    #     loop do
    #       messages = kafka.fetch_messages(
    #         topic: "my-topic",
    #         partition: 42,
    #         offset: offset,
    #       )
    #
    #       messages.each do |message|
    #         puts message.offset, message.key, message.value
    #
    #         # Set the next offset that should be read to be the subsequent
    #         # offset.
    #         offset = message.offset + 1
    #       end
    #     end
    #
    # See a working example in `examples/simple-consumer.rb`.
    #
    # @note This API is still alpha level. Don't try to use it in production.
    #
    # @param topic [String] the topic that messages should be fetched from.
    #
    # @param partition [Integer] the partition that messages should be fetched from.
    #
    # @param offset [Integer, Symbol] the offset to start reading from. Default is
    #   the latest offset.
    #
    # @param max_wait_time [Integer] the maximum amount of time to wait before
    #   the server responds, in seconds.
    #
    # @param min_bytes [Integer] the minimum number of bytes to wait for. If set to
    #   zero, the broker will respond immediately, but the response may be empty.
    #   The default is 1 byte, which means that the broker will respond as soon as
    #   a message is written to the partition.
    #
    # @param max_bytes [Integer] the maximum number of bytes to include in the
    #   response message set. Default is 1 MB. You need to set this higher if you
    #   expect messages to be larger than this.
    #
    # @return [Array<Kafka::FetchedMessage>] the messages returned from the broker.
    def fetch_messages(topic:, partition:, offset: :latest, max_wait_time: 5, min_bytes: 1, max_bytes: 1048576)
      operation = FetchOperation.new(
        cluster: @cluster,
        logger: @logger,
        min_bytes: min_bytes,
        max_wait_time: max_wait_time,
      )

      operation.fetch_from_partition(topic, partition, offset: offset, max_bytes: max_bytes)

      operation.execute.flat_map {|batch| batch.messages }
    end

    # Enumerate all messages in a topic.
    #
    # @param topic [String] the topic to consume messages from.
    #
    # @param start_from_beginning [Boolean] whether to start from the beginning
    #   of the topic or just subscribe to new messages being produced. This
    #   only applies when first consuming a topic partition – once the consumer
    #   has checkpointed its progress, it will always resume from the last
    #   checkpoint.
    #
    # @param max_wait_time [Integer] the maximum amount of time to wait before
    #   the server responds, in seconds.
    #
    # @param min_bytes [Integer] the minimum number of bytes to wait for. If set to
    #   zero, the broker will respond immediately, but the response may be empty.
    #   The default is 1 byte, which means that the broker will respond as soon as
    #   a message is written to the partition.
    #
    # @param max_bytes [Integer] the maximum number of bytes to include in the
    #   response message set. Default is 1 MB. You need to set this higher if you
    #   expect messages to be larger than this.
    #
    # @return [nil]
    def each_message(topic:, start_from_beginning: true, max_wait_time: 5, min_bytes: 1, max_bytes: 1048576, &block)
      default_offset ||= start_from_beginning ? :earliest : :latest
      offsets = Hash.new { default_offset }

      loop do
        operation = FetchOperation.new(
          cluster: @cluster,
          logger: @logger,
          min_bytes: min_bytes,
          max_wait_time: max_wait_time,
        )

        @cluster.partitions_for(topic).map(&:partition_id).each do |partition|
          partition_offset = offsets[partition]
          operation.fetch_from_partition(topic, partition, offset: partition_offset, max_bytes: max_bytes)
        end

        batches = operation.execute

        batches.each do |batch|
          batch.messages.each(&block)
          offsets[batch.partition] = batch.last_offset + 1
        end
      end
    end

    # Lists all topics in the cluster.
    #
    # @return [Array<String>] the list of topic names.
    def topics
      @cluster.clear_target_topics
      @cluster.topics
    end

    # Counts the number of partitions in a topic.
    #
    # @param topic [String]
    # @return [Integer] the number of partitions in the topic.
    def partitions_for(topic)
      @cluster.partitions_for(topic).count
    end

    # Retrieve the offset of the last message in a partition. If there are no
    # messages in the partition -1 is returned.
    #
    # @param topic [String]
    # @param partition [Integer]
    # @return [Integer] the offset of the last message in the partition, or -1 if
    #   there are no messages in the partition.
    def last_offset_for(topic, partition)
      # The offset resolution API will return the offset of the "next" message to
      # be written when resolving the "latest" offset, so we subtract one.
      @cluster.resolve_offset(topic, partition, :latest) - 1
    end

    # Closes all connections to the Kafka brokers and frees up used resources.
    #
    # @return [nil]
    def close
      @cluster.disconnect
    end

    private

    def initialize_cluster
      broker_pool = BrokerPool.new(
        connection_builder: @connection_builder,
        logger: @logger,
      )

      Cluster.new(
        seed_brokers: @seed_brokers,
        broker_pool: broker_pool,
        logger: @logger,
      )
    end

    def build_ssl_context(ca_cert, client_cert, client_cert_key)
      return nil unless ca_cert || client_cert || client_cert_key

      ssl_context = OpenSSL::SSL::SSLContext.new

      if client_cert && client_cert_key
        ssl_context.set_params(
          cert: OpenSSL::X509::Certificate.new(client_cert),
          key: OpenSSL::PKey::RSA.new(client_cert_key)
        )
      elsif client_cert && !client_cert_key
        raise ArgumentError, "Kafka client initialized with `ssl_client_cert` but no `ssl_client_cert_key`. Please provide both."
      elsif !client_cert && client_cert_key
        raise ArgumentError, "Kafka client initialized with `ssl_client_cert_key`, but no `ssl_client_cert`. Please provide both."
      end

      if ca_cert
        store = OpenSSL::X509::Store.new
        store.add_cert(OpenSSL::X509::Certificate.new(ca_cert))
        ssl_context.cert_store = store
      end

      ssl_context
    end

    def normalize_seed_brokers(seed_brokers)
      if seed_brokers.is_a?(String)
        seed_brokers = seed_brokers.split(",")
      end
      brokers = []
      seed_brokers.each do |connection|
        connection.prepend("kafka://") unless connection =~ /:\/\//
        uri = URI.parse(connection)
        uri.port ||= 9092 # Default Kafka port.
        brokers << uri
      end
      brokers
    end
  end
end