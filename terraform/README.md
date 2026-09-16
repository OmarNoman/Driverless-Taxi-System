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
MongoDB (see "Verify the full pipeline" below to reproduce this). Week 8c-i added a
public API Gateway HTTP API + VPC Link fronting dispatch-service, confirmed working
end to end (see "Verify API Gateway (8c-i)" below). Week 8c-ii fixed event-router's
MQTT subscription so it can scale safely (confirmed locally, see `ARCHITECTURE.md`).
Week 8c-iii added CloudWatch alarms + Application Auto Scaling for event-router (CPU
only) and telemetry-service (CPU + SQS queue depth) - see "Verify auto-scaling (8c-iii)"
below. See `ARCHITECTURE.md` for the full design rationale and `ROADMAP.md` for the
plan/validation trace.

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
- **Every ECS service shows `CannotPullContainerError: ... :week8: not found` right
  after a fresh `terraform apply`** - expected on every session, not a bug. Every ECR
  repo here has `force_delete = true` (`ecr.tf`), so the *previous* session's
  `terraform destroy` deleted the repos and every image in them along with everything
  else. A brand-new account has empty repos until you build and push all 5 images
  again (see "Commands" below) - there is no way to skip this step between sessions.
  ECS keeps retrying task placement on its own; once the images land, it recovers
  within a minute or two with no extra nudge needed (`aws ecs update-service
  --force-new-deployment` speeds it up if you want to confirm sooner).
- **PowerShell's `curl` is not curl** - it's an alias for `Invoke-WebRequest`, which
  doesn't understand bash's `-X`, `-H`, `-d`, or `$(...)` syntax and throws confusing
  parameter-binding errors on all of them. Always call `curl.exe` explicitly (the real
  curl binary that ships with Windows 10/11) for anything in this README written with
  curl flags.
- **`terraform output -raw http_api_invoke_url` ends in a trailing `/`, so
  `"$BASE/health"` builds a double slash (`.../amazonaws.com//health`)** - this either
  fails to match any route or reaches dispatch-service with a mismatched path
  (its own `{"error":"not found"}` 404 handler, not an API Gateway error - a sign the
  VPC Link/NLB path *is* working, just with the wrong path string). Trim it once after
  reading the output: `$BASE = ($BASE).TrimEnd('/')`.
- **The first request to the API Gateway URL after a period of idleness returns
  `{"message":"Service Unavailable"}`, while an identical request sent immediately
  afterward succeeds** - confirmed directly: two back-to-back `curl.exe` calls to the
  exact same route, first one failed, second one (no gap) returned `{"ok":true}`. This
  is a connection/VPC-Link warm-up cost after idle time, not a route-specific bug - it
  had looked like it was always `/health` specifically failing purely because that was
  always the first request sent in each test batch, not because anything is wrong with
  that route. **For a live demo:** send one throwaway warm-up request (any route) a few
  seconds before the one you actually want to show, so the connection is already warm
  when it matters.
- **`aws_appautoscaling_target.event_router`/`.telemetry_service` fails with
  `AccessDeniedException` on `iam:CreateServiceLinkedRole`** - this Academy account has
  confirmed-blocked `iam:CreateRole`/`iam:PutRolePolicy` (see `iam.tf`) and Cloud Map,
  but `CreateServiceLinkedRole` (the narrower action ECS's Application Auto Scaling
  needs to provision `AWSServiceRoleForApplicationAutoScaling_ECSAsATarget` on first
  use) had not been separately tested until 8c-iii - this is why 8c-iii's own commands
  apply the 2 scalable targets in isolation first, to surface this cheaply if it
  happens. If it does, the one-time, one-off fix is:
  ```powershell
  aws iam create-service-linked-role --aws-service-name ecs.application-autoscaling.amazonaws.com
  ```
  then re-run `terraform apply`. This is a narrow, one-time account-level action, not a
  Terraform-managed IAM role - it does not need to be added to `iam.tf`.

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
terraform plan      # expect roughly 78 resources to add on a first full apply (8c-i
                    # through 8c-iii included): az_count=2 means 2 public + 2 private
                    # subnets rather than 1 of each, the 7 API Gateway/VPC Link
                    # resources, and 14 auto-scaling resources (2 scalable targets, 6
                    # policies, 6 alarms), on top of everything Week 7/8b provisions
```

**8c-iii only: apply the 2 scalable targets in isolation first**, to cheaply surface an
`AccessDenied` on `iam:CreateServiceLinkedRole` early if this Academy account blocks it
too (only `iam:CreateRole`/`PutRolePolicy` and Cloud Map are confirmed-blocked so far -
this specific action has not been tested here):

```powershell
terraform apply -target=aws_appautoscaling_target.event_router -target=aws_appautoscaling_target.telemetry_service
```

If that succeeds, apply everything else:

```powershell
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

### Verify API Gateway (8c-i)

Confirms the public entry point works end to end: API Gateway HTTP API -> VPC Link ->
internal NLB -> dispatch-service. Use `curl.exe`, not PowerShell's `curl` alias (see
"Common errors" above), and trim the invoke URL's trailing slash before building paths
with it:

```powershell
$BASE = (terraform output -raw http_api_invoke_url).TrimEnd('/')
curl.exe "$BASE/health"    # expect {"ok":true} - retry once if you see "Service Unavailable" (see "Common errors")
curl.exe "$BASE/nodes"     # expect the 21-node landmark list
```

`/rides` needs at least one vehicle with a *known position* to succeed, otherwise
dispatch-service correctly reports none available. Publish one telemetry packet first
(reuses the exact method from "Verify the full pipeline" above - get Mosquitto's public
IP, then publish a TAXI-001 packet), then request a ride:

```powershell
'{"userId":1,"pickup":"Camberwell","dropoff":"St Kilda","passengers":2}' |
  Out-File -FilePath "$env:TEMP\ride.json" -Encoding ascii -NoNewline
curl.exe -X POST "$BASE/rides" -H "content-type: application/json" -d "@$env:TEMP\ride.json"
```

Expect a 200 with `rideId`/`vehicleId`/`route` - the same shape already proven directly
against the NLB target group in 8b, now reachable from a public HTTPS URL instead of
only from inside the VPC. Also worth trying one bad-input case (e.g. an unknown
landmark name) to confirm API Gateway passes dispatch-service's own error response
through unchanged rather than swallowing or rewriting it.

### Verify auto-scaling (8c-iii)

event-router scales on CPU only; telemetry-service scales on CPU and SQS queue depth
(`dtx-telemetry-queue`) - event-router never drains that queue, only telemetry-service
does, so a queue-depth trigger on event-router wouldn't relieve anything (see
`ARCHITECTURE.md` for the full reasoning, this is a deliberate, documented departure
from the plan's literal wording).

Confirm the scalable targets and alarms exist:

```powershell
aws application-autoscaling describe-scalable-targets --service-namespace ecs
aws cloudwatch describe-alarms --alarm-names (terraform output -json cloudwatch_alarm_names | ConvertFrom-Json)
```

Real load (500 simulated vehicles from Week 9) will trigger this naturally. For a quick
demo without waiting on sustained traffic, **do not use `aws cloudwatch
set-alarm-state`** - tried directly in this project, it changes the alarm's displayed
state but does not reliably invoke the associated scaling policy (a manual override is
not the same as a real state transition from CloudWatch's own evaluation, and the one
time it was tried here the scaling effect only showed up later, stacked on top of a
separate real transition, made a genuine test result impossible to read cleanly).

The technique that is confirmed to work, twice, in this project: temporarily lower a
threshold in `terraform/autoscaling.tf` to below the metric's *real*, currently-observed
value, so a genuine CloudWatch evaluation crosses it on its own. telemetry-service's
real CPU sits around 0.2-0.25% at idle - edit `telemetry_service_cpu_high`'s `threshold`
from `70` down to `0.1`, then:

```powershell
terraform apply
```

Wait 2-3 minutes for two real 60-second CPU datapoints to cross it, then check:

```powershell
aws cloudwatch describe-alarms --alarm-names dtx-telemetry-service-cpu-high --query "MetricAlarms[0].StateValue"
aws ecs describe-services --cluster dtx-cluster --services dtx-event-router dtx-telemetry-service --query "services[].{name:serviceName,desired:desiredCount,running:runningCount}"
```

Confirmed result in this project: the alarm entered `ALARM` and `dtx-telemetry-service`
climbed from `desired: 1` all the way to `desired: 3` (the configured `max_capacity`).
Revert the threshold back to `70`, `terraform apply` again, and within a few minutes the
already-armed `dtx-telemetry-service-cpu-low` alarm (30% threshold, real CPU is far
below it) brings it back down - confirmed in this project settling cleanly back to
`desired: 1, running: 1`. `aws cloudwatch describe-alarms` at each stage gives the
state-transition evidence for the report (`StateValue`, `StateReason`,
`StateTransitionedTimestamp`). The same threshold-lowering technique works on any of
the 6 alarms if a demo needs to show a specific one (e.g. event-router's CPU alarms, or
telemetry-service's SQS alarms with a real, if brief, burst of messages).

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
