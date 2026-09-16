# Terraform - AWS deployment

Provisions and runs the whole system on AWS:

- A VPC with a public subnet for Mosquitto and a private subnet for the three Node.js
  services and both databases, VPC endpoints instead of a NAT Gateway.
- An ECS Fargate cluster running all 6 things (event-router, telemetry-service,
  dispatch-service, Postgres, Mongo, Mosquitto).
- An internal Network Load Balancer for service-to-service discovery (one listener/target
  group per port), used instead of AWS Cloud Map, which is blocked in this AWS Academy
  Learner Lab account.
- An SQS queue plus a dead-letter queue, buffering between event-router and
  telemetry-service.
- A public API Gateway HTTP API with a VPC Link, fronting dispatch-service over HTTPS.
- CloudWatch alarms and AWS Application Auto Scaling on event-router (CPU) and
  telemetry-service (CPU and SQS queue depth), scaling each between 1 and 3 tasks.
- The Postgres password and connection string stored in AWS SSM Parameter Store as
  `SecureString` parameters rather than plaintext Terraform variables.
- 5 ECR repositories: one per Node.js service, plus one each for the custom-seeded
  Postgres and Mongo images.

## Prerequisites

- Terraform >= 1.7 (`terraform -version`).
- An AWS Academy Learner Lab session, since this account cannot create IAM
  roles/policies and only issues temporary STS credentials.

## Every session: get fresh credentials first

AWS Academy Learner Lab credentials expire after a few hours. At the start of
**every** work session:

1. Start the lab, open **AWS Details**, click **Show** next to AWS CLI credentials.
2. Copy the three values into your shell (PowerShell):

   ```powershell
   $env:AWS_ACCESS_KEY_ID = "..."
   $env:AWS_SECRET_ACCESS_KEY = "..."
   $env:AWS_SESSION_TOKEN = "..."
   $env:AWS_DEFAULT_REGION = "us-east-1"
   ```

   Never write these into any `.tf`, `.tfvars`, or other committed file. Terraform
   reads its region from `terraform.tfvars`; the AWS CLI needs its own
   `AWS_DEFAULT_REGION` (or a `--region` flag on every command), set separately here.
3. Confirm they work: `aws sts get-caller-identity`.

If a `plan`/`apply` fails partway through with an `ExpiredToken` error, repeat step 2
with a fresh set of credentials and re-run the same command; every resource here is
idempotent.

## Deploy

Build and push all 5 images (3 Node.js services + 2 custom-seeded databases), all
tagged `:week8` to match what `terraform/ecs.tf`'s task definitions reference. Do this
before `terraform apply`, since a service that comes up before its image exists just
sits retrying pulls:

```powershell
cd <repo root>
docker build -f services/event-router/Dockerfile -t dtx-event-router:week8 .
docker build -f services/dispatch-service/Dockerfile -t dtx-dispatch-service:week8 .
docker build -t dtx-telemetry-service:week8 services/telemetry-service
docker build -t dtx-postgres-seeded:week8 db/postgres
docker build -f db/mongo/Dockerfile -t dtx-mongo-seeded:week8 .

$tokenFile = "$env:TEMP\ecr-token.txt"
aws ecr get-login-password --region us-east-1 | Out-File -FilePath $tokenFile -Encoding ascii -NoNewline
cmd /c "docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com < `"$tokenFile`""
Remove-Item $tokenFile

foreach ($name in "event-router","dispatch-service","telemetry-service","postgres-seeded","mongo-seeded") {
  docker tag "dtx-$name`:week8" "<account-id>.dkr.ecr.us-east-1.amazonaws.com/dtx-$name`:week8"
  docker push "<account-id>.dkr.ecr.us-east-1.amazonaws.com/dtx-$name`:week8"
}
```

(`terraform output ecr_repository_urls` prints the exact repository URLs once applied
at least once)

Then apply:

```powershell
cd terraform
terraform init
terraform validate
terraform plan
terraform apply
```

## Verify

Confirm every ECS service is up and every NLB target is healthy:

```powershell
aws ecs describe-services --cluster dtx-cluster --services dtx-event-router dtx-telemetry-service dtx-dispatch-service dtx-postgres dtx-mongo dtx-mosquitto --query "services[].{name:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount}"

foreach ($tg in "dtx-postgres-tg","dtx-mongo-tg","dtx-mosquitto-tg","dtx-dispatch-tg") {
  $arn = aws elbv2 describe-target-groups --names $tg --query "TargetGroups[0].TargetGroupArn" --output text
  "$tg`: $(aws elbv2 describe-target-health --target-group-arn $arn --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
}
```

`running == desired` for all 6 services and `healthy` for all 4 target groups confirms
the deployment and internal service discovery are both working.

### Verify the API Gateway

Use `curl.exe` explicitly on Windows (PowerShell's `curl` alias is `Invoke-WebRequest`
and does not understand curl flags), and trim the invoke URL's trailing slash before
building paths with it:

```powershell
$BASE = (terraform output -raw http_api_invoke_url).TrimEnd('/')
curl.exe "$BASE/health"    # expect {"ok":true}
curl.exe "$BASE/nodes"     # expect the 21-node landmark list
```

`/rides` needs at least one vehicle with a known position (publish a telemetry packet
via Mosquitto's public IP first, or have Node-RED running against the deployment):

```powershell
'{"userId":1,"pickup":"Camberwell","dropoff":"St Kilda","passengers":2}' |
  Out-File -FilePath "$env:TEMP\ride.json" -Encoding ascii -NoNewline
curl.exe -X POST "$BASE/rides" -H "content-type: application/json" -d "@$env:TEMP\ride.json"
```

### Verify auto-scaling

```powershell
aws application-autoscaling describe-scalable-targets --service-namespace ecs
aws cloudwatch describe-alarms --alarm-names (terraform output -json cloudwatch_alarm_names | ConvertFrom-Json)
```

Sustained load (e.g. the Node-RED load-test tooling, see [`node-red/`](../node-red))
will trigger real scaling: event-router scales on CPU, telemetry-service scales on CPU
and SQS queue depth (`dtx-telemetry-queue`). Watch it happen:

```powershell
aws ecs describe-services --cluster dtx-cluster --services dtx-event-router dtx-telemetry-service --query "services[].{name:serviceName,desired:desiredCount,running:runningCount}"
```

## Always destroy before ending the session

```powershell
terraform destroy
```

This is not optional. Closing the Lab browser tab does not stop billing; the interface
VPC endpoints, the NLB, the API Gateway, and all 6 running Fargate tasks keep costing
money against the fixed, non-resetting Lab budget until they are actually destroyed.

If the Lab resets your whole account between sessions (some course configurations do
this), the local `terraform.tfstate` can go stale. Run `terraform plan` at the start of
a session too, not just before ending it, to catch drift early.

## Budget

With all 6 Fargate tasks running (steady state, no auto-scaling triggered), total cost
is roughly $0.15-0.16/hr: Fargate vCPU/GB-hour pricing dominates, the VPC endpoints and
NLB add a small fixed idle cost, and SQS/CloudWatch stay effectively free at this demo's
message volume. Leaving it up overnight by accident is a few dollars, not a rounding
error, so `terraform destroy` matters every session.
