# Terraform - AWS networking, registry, and the running stack

Week 7 provisioned the AWS VPC and container registry: a public subnet for Mosquitto,
private subnets for the services and both databases, VPC endpoints instead of a NAT
Gateway, and one ECR repository per Node.js service. Week 8b added everything that
actually runs: an ECS Fargate cluster and 6 services (the 3 Node.js services, Postgres,
Mongo, Mosquitto), an internal Network Load Balancer for service-to-service discovery
(not Cloud Map, see "Cloud Map is blocked in this account" below), the SQS queue + DLQ
the plan requires between the broker and the database, 2 more ECR repos for the
custom-seeded database images, and two security-group fixes Week 7 deliberately deferred
plus one the NLB itself required. **Confirmed working end to end**: all 6 services reach
`running == desired`, and a live MQTT publish through Mosquitto's public IP has been
proven to flow all the way through event-router, SQS, and telemetry-service into
MongoDB (see "Verify the full pipeline" below to reproduce this). No API Gateway or
auto-scaling policies yet, that is Week 8c. See `ARCHITECTURE.md` for the full design
rationale and `ROADMAP.md` for the plan/validation trace.

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
   reads its region from `terraform.tfvars`, but the AWS CLI needs its own
   `AWS_DEFAULT_REGION` (or a `--region` flag on every command), it does not pick
   one up from Terraform's config, so set it here too or every `aws` command fails
   with `NoRegion`.
3. Confirm they work: `aws sts get-caller-identity`.

If a `plan`/`apply` fails partway through with an `ExpiredToken` error, just repeat
step 2 with a fresh set of credentials and re-run the same command, every resource
here is idempotent.

## Common errors

- **`aws: [ERROR]: An error occurred (NoRegion): You must specify a region.`** - you
  forgot `$env:AWS_DEFAULT_REGION = "us-east-1"` from step 2 above. This one is easy
  to forget because `terraform` commands don't need it (region comes from
  `terraform.tfvars` instead), only the `aws` CLI does. Fix: set it, then re-run the
  same `aws` command, no need to touch Terraform.
- **`ExpiredToken`** - see above, re-export fresh credentials and re-run.
- **`docker login` to ECR fails with `400 Bad Request`, then `docker push` fails with
  `no basic auth credentials`, even with a confirmed-valid token** - a PowerShell
  gotcha, not a real auth problem. PowerShell's pipeline re-terminates the line when
  writing a string to a native process's stdin regardless of `.Trim()` on the source
  string, which corrupts the base64 ECR token before `docker login --password-stdin`
  reads it. The only reliable fix is to bypass PowerShell's pipe entirely: write the
  token to a file with `-NoNewline`, then redirect that file into `docker login`'s
  stdin via `cmd /c` (OS-level redirection, not PowerShell's pipeline machinery).
  ```powershell
  $tokenFile = "$env:TEMP\ecr-token.txt"
  aws ecr get-login-password --region us-east-1 | Out-File -FilePath $tokenFile -Encoding ascii -NoNewline
  cmd /c "docker login --username AWS --password-stdin <account-id>.dkr.ecr.us-east-1.amazonaws.com < `"$tokenFile`""
  Remove-Item $tokenFile
  ```
- **`docker tag`/`docker push` fail with `failed to connect to the docker API at
  npipe:...`** - Docker Desktop isn't running. Start it and wait for it to fully
  come up before retrying.
- **`servicediscovery:CreatePrivateDnsNamespace`/`CreateHttpNamespace` both fail with
  `AccessDeniedException`** - AWS Cloud Map is entirely blocked for the Academy
  `voclabs` role in this account, confirmed directly (both the classic Service
  Discovery and the ECS Service Connect namespace types were tested). This is why
  internal service discovery uses an internal Network Load Balancer (`nlb.tf`)
  instead, not something to retry or work around, it will not start working.
- **An ECS service stuck with `runningCount: 0` and events repeating
  `ResourceInitializationError: ... connection issue between the task and Amazon
  CloudWatch`** - not a CloudWatch problem, a security-group one. The `logs` VPC
  endpoint has `private_dns_enabled = true`, so `logs.us-east-1.amazonaws.com`
  resolves to the endpoint's private IP for every resource in the VPC, including
  ones in the *public* subnet, not just the private one. The endpoint's own security
  group only accepts 443 from `internal_services`, so any task that only carries a
  different security group (this hit Mosquitto specifically, its own SG is separate)
  can resolve the hostname but gets silently refused at the TCP level. Fix: that
  task's `aws_ecs_service` needs `internal_services` added as a second security
  group, purely so its `awslogs` traffic has a path to the endpoint, exactly the same
  pattern already used for Postgres/Mongo (there, it was originally added for ECR
  pulls, and happens to cover this too).
- **An NLB target group's target stays `unhealthy` (or a dependent service crashes
  with `MongoServerSelectionError`/similar connection timeouts) even though the
  container itself is fine** - the NLB's own health-check probes for `ip`-type
  targets originate from the load balancer's own ENIs, not from any container
  carrying one of our security groups, so a security-group-*referenced* ingress rule
  (`security_groups = [...]`) never matches them, only a CIDR-based rule does. Fixed
  by adding a `cidr_blocks = [var.vpc_cidr]` ingress rule alongside the existing
  SG-referenced one on `database` (5432/27017) and `internal_services` (8080).
  Mosquitto was never affected, its 1883 listener is already open to `0.0.0.0/0`.
- **`telemetry-service` logs `sqs receive failed: connect ETIMEDOUT <ip>:443`** - a
  missing VPC endpoint, found by hitting it directly. Unlike ECR/CloudWatch Logs, SQS
  never had its own interface endpoint (`vpc-endpoints.tf` only had s3/ecr.api/ecr.dkr
  /logs), so a private-subnet task has no route to it at all with no NAT Gateway. The
  periodic stats ticker logging every 10s regardless of whether the SQS call actually
  succeeded made this easy to miss at a glance, don't read "the logs look mostly fine"
  as proof SQS is reachable, check for this specific error string instead. Fixed by
  adding `aws_vpc_endpoint.sqs` (same pattern as the other three interface endpoints).
- **event-router logs `REJECT ...: payload is not valid JSON` for a test message you're
  sure was valid JSON** - almost certainly a PowerShell quoting problem, not a schema
  problem. Passing an inline JSON string with embedded double quotes through
  `docker run ... mosquitto_pub -m $payload` gets mangled somewhere across
  PowerShell -> docker -> the container's own argument parsing. Write the JSON to a
  file and use `mosquitto_pub -f <file>` instead (see "Verify the full pipeline"
  above), which sidesteps command-line quoting entirely.
- **`describe-log-streams --order-by LastEventTime --descending --max-items 1` returns
  nothing (`$stream` ends up as the literal text `None`, then the next command fails
  with `Unknown options: None`)** - not a real error, `lastEventTimestamp` in that API
  is only eventually consistent and can lag well behind what's actually been ingested,
  so ordering by it can miss recently-active streams entirely. Don't chase this
  further, build the stream name directly from the live task ID instead (see "Verify
  the full pipeline" above), it's always accurate.

## Commands

**Order matters for 8b**: push the images to ECR (they need to exist for the task
definitions to reference), then apply. `terraform apply` will still succeed either way
(task definitions just reference an image URI/tag, they don't validate it exists until
ECS actually tries to start a task), but a service that comes up before its image
exists just sits retrying pulls, so push first to skip the confusion.

```powershell
cd terraform
terraform init
terraform validate
terraform plan      # expect roughly 45-50 resources to add on a first Week 8b run
terraform apply
```

Build and push all 5 images (3 Node.js services + 2 custom-seeded databases), all
tagged `:week8` to match what `terraform/ecs.tf`'s task definitions reference:

```powershell
cd ..   # repo root
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
(see "Common errors" above for why the login can't just be a plain PowerShell pipe;
`terraform output ecr_repository_urls` prints the exact repository URLs once applied)

Verify against the live account (not just the state file):

```powershell
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=sit314-driverless-taxi"
aws ec2 describe-subnets --filters "Name=tag:Project,Values=sit314-driverless-taxi"
aws ec2 describe-vpc-endpoints --filters "Name=tag:Project,Values=sit314-driverless-taxi"
aws ec2 describe-security-groups --filters "Name=tag:Project,Values=sit314-driverless-taxi"
aws ecr describe-repositories
aws ecs describe-services --cluster dtx-cluster --services dtx-event-router dtx-telemetry-service dtx-dispatch-service dtx-postgres dtx-mongo dtx-mosquitto --query "services[].{name:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount}"
aws sqs get-queue-attributes --queue-url $(terraform output -raw sqs_queue_url) --attribute-names ApproximateNumberOfMessages

foreach ($tg in "dtx-postgres-tg","dtx-mongo-tg","dtx-mosquitto-tg","dtx-dispatch-tg") {
  $arn = aws elbv2 describe-target-groups --names $tg --query "TargetGroups[0].TargetGroupArn" --output text
  "$tg`: $(aws elbv2 describe-target-health --target-group-arn $arn --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
}
```

`running == desired` for all 6 ECS services is the concrete proof both pull paths work:
ECR-via-endpoints for the 5 private-subnet services, Docker-Hub-via-IGW for Mosquitto.
Each target group should say `healthy`, that's the concrete proof internal discovery via
the NLB works (see "Cloud Map is blocked in this account" below for why this isn't Cloud
Map). If a service is stuck below its desired count, `aws ecs describe-tasks` on its most
recent task (find the ARN via `aws ecs list-tasks --cluster dtx-cluster --service-name
<name>`) shows the stopped reason. Two gotchas already hit and fixed here, both in
"Common errors" below: an NLB target staying `unhealthy` almost always means the
NLB-health-check-vs-security-group gap, not a broken container; `runningCount: 0` with a
CloudWatch-connection error in the events is the `logs` VPC endpoint's security-group gap,
not an actual CloudWatch problem.

### Verify the full pipeline

Prove real data flows end to end (MQTT in, MongoDB out), not just that the services are
up. Get Mosquitto's current public IP first (it's not an Elastic IP, it changes every
time the task restarts):

```powershell
$taskArn = aws ecs list-tasks --cluster dtx-cluster --service-name dtx-mosquitto --query "taskArns[0]" --output text
$eniId = aws ecs describe-tasks --cluster dtx-cluster --tasks $taskArn --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text
$publicIp = aws ec2 describe-network-interfaces --network-interface-ids $eniId --query "NetworkInterfaces[0].Association.PublicIp" --output text
```

Publish a valid sedan telemetry packet. Write it to a file first, PowerShell mangles
quotes badly enough passing an inline JSON string through `docker run` that the message
arrives corrupted (see "Common errors" below):

```powershell
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$json = @"
{"vehicleID":"TAXI-001","vehicleType":"sedan","coordinates":{"lat":-37.8136,"lon":144.9631},"heading":90,"speed":34.2,"batteryLevel":87.4,"currentState":"driving","timestamp":$ts,"occupancy":{"seatsTotal":4,"seatsOccupied":1,"seatWeightKg":70},"doorsLocked":true}
"@
$json | Out-File -FilePath "$env:TEMP\payload.json" -Encoding ascii -NoNewline
docker run --rm -v "${env:TEMP}:/data" eclipse-mosquitto:2 mosquitto_pub -h $publicIp -p 1883 -t 'fleet/TAXI-001/telemetry' -f /data/payload.json
Start-Sleep -Seconds 10
```

Then confirm it made it all the way through, using each service's *current* task
(`describe-log-streams --order-by LastEventTime` is unreliable, its `lastEventTimestamp`
field is only eventually-consistent and can be stale by a long way - build the stream
name from the live task ID instead):

```powershell
$erTaskArn = aws ecs list-tasks --cluster dtx-cluster --service-name dtx-event-router --query "taskArns[0]" --output text
$erTaskId = ($erTaskArn -split '/')[-1]
aws logs get-log-events --log-group-name /ecs/dtx-event-router --log-stream-name "event-router/event-router/$erTaskId" --query "events[?contains(message, 'sqs') || contains(message, 'OK ')].message" --output text

$tsTaskArn = aws ecs list-tasks --cluster dtx-cluster --service-name dtx-telemetry-service --query "taskArns[0]" --output text
$tsTaskId = ($tsTaskArn -split '/')[-1]
aws logs get-log-events --log-group-name /ecs/dtx-telemetry-service --log-stream-name "telemetry-service/telemetry-service/$tsTaskId" --query "events[?contains(message, 'flushed')].message" --output text
```

Expect `OK TAXI-001 ...` plus a confirmed SQS publish from event-router, and
`flushed 1 vehicles ...` from telemetry-service. A `sqs get-queue-attributes` check
straight after publishing should briefly show `1`, then drop back to `0` once
telemetry-service's 5-second batch flushes and deletes it, that's the delete-after-flush
durability design (see `ARCHITECTURE.md`) working as intended, not a bug.

### Cloud Map is blocked in this account

AWS Cloud Map (`servicediscovery:*`) is entirely denied for the Academy `voclabs` role
here, confirmed directly: both `CreatePrivateDnsNamespace` (classic ECS Service
Discovery) and `CreateHttpNamespace` (what ECS Service Connect uses) return
`AccessDeniedException`. Internal service-to-service discovery uses an internal Network
Load Balancer instead (`nlb.tf`) - one NLB, one listener/target group per port, ECS's
native `load_balancer` block on each service registers/deregisters automatically, no
Cloud Map involved anywhere. If you ever move this to a non-Academy AWS account, Cloud
Map would work fine and is arguably the more idiomatic choice, this NLB detour is
specific to this account's restrictions, not a general recommendation.

## Always destroy before ending the session

```powershell
terraform destroy
```

This is not optional. Closing the Lab browser tab does not stop billing, the 4
interface VPC endpoints, the NLB, and (from 8b) 6 running Fargate tasks all keep
running (and keep costing money against the fixed, non-resetting Lab budget) until
they are actually destroyed. Confirm nothing is left with the same
`describe-*`/`describe-repositories` commands above.

If the Lab resets your whole account between sessions (some course configurations
do this), the local `terraform.tfstate` can go stale. Run `terraform plan` at the
**start** of a session too, not just before ending it, to catch drift early.

## Budget

Week 7's networking alone cost about $0.03/hr idle (3 interface VPC endpoints); 8b
added a 4th (SQS) and an internal NLB. **With all 6 Fargate tasks running (steady
state, no auto-scaling yet), total is roughly $0.15-0.16/hr** - Fargate's own
vCPU/GB-hour pricing dominates now, SQS and CloudWatch Logs stay effectively free at
this demo's tiny message volume. Leaving it up overnight by accident is now a few
dollars, not a rounding error, so `terraform
destroy` really matters from 8b onward, not just as a principle.
