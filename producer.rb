#!/usr/bin/env ruby

require "kafka"

kafka = Kafka.new(
  # At least one of these nodes must be available:
  seed_brokers: ["ec2-52-207-103-240.compute-1.amazonaws.com:9096","ec2-54-87-146-57.compute-1.amazonaws.com:9096","ec2-54-87-148-197.compute-1.amazonaws.com:9096"],
  # Set an optional client id in order to identify the client to Kafka:
  client_id: "andrewjamesbrown",
  )

kafka.deliver_message("Hello, World!", topic: "andrewjamesbrown")