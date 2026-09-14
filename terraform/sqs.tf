# The SQS buffer "between the MQTT broker and the database" the plan requires (Solution
# Overview). Standard, not FIFO: the batcher's own last-write-wins-by-timestamp logic
# already tolerates out-of-order delivery, so FIFO's ordering guarantee (and its much
# lower throughput ceiling) buys nothing here.

resource "aws_sqs_queue" "telemetry_dlq" {
  name = "${var.project_name}-telemetry-dlq"

  tags = {
    Name = "${var.project_name}-telemetry-dlq"
  }
}

resource "aws_sqs_queue" "telemetry" {
  name = "${var.project_name}-telemetry-queue"

  # Comfortably longer than the 5s batch window, so a message isn't returned to the
  # queue (and redelivered) while telemetry-service is still mid-flush with it.
  visibility_timeout_seconds = 60

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.telemetry_dlq.arn
    maxReceiveCount     = 5
  })

  tags = {
    Name = "${var.project_name}-telemetry-queue"
  }
}
