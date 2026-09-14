# AWS Academy Learner Lab blocks iam:CreateRole/PutRolePolicy etc. Every ECS task in
# this project uses the pre-existing "LabRole" for both the execution role (pull images
# from ECR, write logs) and the task role (application runtime credentials, e.g. the SQS
# calls in event-router/telemetry-service), looked up here, never created.
#
# LabRole's actual attached permissions for this specific workload (ECS task
# execution + SQS send/receive/delete + CloudWatch Logs) are unverified - the first
# successful task reaching RUNNING and writing a log line doubles as the smoke test.
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}
