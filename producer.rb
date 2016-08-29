#!/usr/bin/env ruby

require "kafka"

kafka = Kafka.new(
  
  # At least one of these nodes must be available:
  seed_brokers: ["kafka+ssl://ec2-52-207-103-240.compute-1.amazonaws.com:9096", "kafka+ssl://ec2-54-87-146-57.compute-1.amazonaws.com:9096", "kafka+ssl://ec2-54-87-148-197.compute-1.amazonaws.com:9096"],
  # Set an optional client id in order to identify the client to Kafka:
  client_id: "andrewjamesbrown",
  ssl_ca_cert: ENV['KAFKA_TRUSTED_CERT'],
  ssl_client_cert: ENV['KAFKA_CLIENT_CERT'],
  ssl_client_cert_key: ENV['KAFKA_CLIENT_CERT_KEY'],
  )

while true
  kafka.deliver_message("Hello, World!", topic: "andrewjamesbrown")
  puts "Delivering kafka message...."
  sleep 1
end
