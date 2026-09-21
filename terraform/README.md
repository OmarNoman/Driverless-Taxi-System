# Terraform - AWS deployment

Provisions and runs the whole system on AWS:

- A VPC with a public subnet for Mosquitto and a private subnet for the three Node.js
  services and both databases, VPC endpoints instead of a NAT Gateway.
- An ECS Fargate cluster running all 8 things (event-router, telemetry-service,
  dispatch-service, Postgres, Mongo primary, Mongo secondary, Mosquitto, Redis).
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
- 6 ECR repositories: one per Node.js service, one each for the custom-seeded Postgres
  and Mongo images, and one for Redis.
- A Redis cache-aside layer (6.4HD) in front of dispatch-service's vehicle-lookup query,
  on the internal NLB alongside Postgres/Mongo/Mosquitto.
- A MongoDB replica set (6.4HD): a second `mongod --replSet dtxrs` member alongside the
  primary, on its own NLB listener (port 27018). dispatch-service (the system's only
  Mongo reader) connects with `readPreference=secondaryPreferred`, offloading
  `telemetry` reads onto the secondary. telemetry-service (writes only) is untouched.

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

**Apply first, then push images.** The ECR repositories themselves are created by
Terraform (`terraform/ecr.tf`); on a fresh account (or after a previous session's
`terraform destroy`, which deletes them since they're `force_delete = true`) they don't
exist yet, so a push before applying fails with "repository does not exist".

```powershell
cd terraform
terraform init
terraform validate
terraform plan
terraform apply
```

ECS services will initially fail to pull images (`CannotPullContainerError`) since the
repos are empty right after a fresh apply - expected, not a bug. They recover on their
own within a minute or two of the push below landing.

Build and push all 5 base-project images (3 Node.js services + 2 custom-seeded
databases), all tagged `:week8` to match what `terraform/ecs.tf`'s task definitions
reference, from the repo root (`cd ..` if you're still in `terraform/`):

```powershell
docker build -f services/event-router/Dockerfile -t dtx-event-router:week8 .
docker build -f services/dispatch-service/Dockerfile -t dtx-dispatch-service:week8 .
docker build -t dtx-telemetry-service:week8 services/telemetry-service
docker build -t dtx-postgres-seeded:week8 db/postgres
docker build -f db/mongo/Dockerfile -t dtx-mongo-seeded:week8 .

$accountId = aws sts get-caller-identity --query Account --output text

$tokenFile = "$env:TEMP\ecr-token.txt"
aws ecr get-login-password --region us-east-1 | Out-File -FilePath $tokenFile -Encoding ascii -NoNewline
cmd /c "docker login --username AWS --password-stdin $accountId.dkr.ecr.us-east-1.amazonaws.com < `"$tokenFile`""
Remove-Item $tokenFile

foreach ($name in "event-router","dispatch-service","telemetry-service","postgres-seeded","mongo-seeded") {
  docker tag "dtx-$name`:week8" "$accountId.dkr.ecr.us-east-1.amazonaws.com/dtx-$name`:week8"
  docker push "$accountId.dkr.ecr.us-east-1.amazonaws.com/dtx-$name`:week8"
}
```

Then build and push the 6.4HD Redis image, tagged `:week9` to match
`terraform/ecs.tf`'s `aws_ecs_task_definition.redis`:

```powershell
docker build -t dtx-redis:week9 db/redis
docker tag dtx-redis:week9 "$accountId.dkr.ecr.us-east-1.amazonaws.com/dtx-redis:week9"
docker push "$accountId.dkr.ecr.us-east-1.amazonaws.com/dtx-redis:week9"
```

And the 6.4HD MongoDB replica-set secondary image, tagged `:week9-secondary` and pushed
to the *existing* `dtx-mongo-seeded` repo (same repo as the primary, different tag):

```powershell
docker build -f db/mongo/Dockerfile.secondary -t dtx-mongo-seeded:week9-secondary .
docker tag dtx-mongo-seeded:week9-secondary "$accountId.dkr.ecr.us-east-1.amazonaws.com/dtx-mongo-seeded:week9-secondary"
docker push "$accountId.dkr.ecr.us-east-1.amazonaws.com/dtx-mongo-seeded:week9-secondary"
```

(`terraform output ecr_repository_urls` also prints the exact repository URLs, useful
to double check `$accountId` resolved correctly)

**Rebuilding an image under the same tag doesn't trigger a redeploy on its own.**
Terraform's task definitions reference a tag (`:week8`, `:week9`, ...), not an image
digest, so pushing new content under a tag Terraform already deployed leaves `plan`
showing no changes - ECS keeps running the old image until you force it:

```powershell
aws ecs update-service --cluster dtx-cluster --service <service-name> --force-new-deployment
```

(`dtx-dispatch-service`, `dtx-postgres`, `dtx-mongo`, etc. Hit this directly when
iterating on `store.js` for Technique 1 and on `init-telemetry.sh` for Technique 2.)

## Verify

Confirm every ECS service is up and every NLB target is healthy:

```powershell
aws ecs describe-services --cluster dtx-cluster --services dtx-event-router dtx-telemetry-service dtx-dispatch-service dtx-postgres dtx-mongo dtx-mongo-secondary dtx-mosquitto dtx-redis --query "services[].{name:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount}"

foreach ($tg in "dtx-postgres-tg","dtx-mongo-tg","dtx-mongo-secondary-tg","dtx-mosquitto-tg","dtx-dispatch-tg","dtx-redis-tg") {
  $arn = aws elbv2 describe-target-groups --names $tg --query "TargetGroups[0].TargetGroupArn" --output text
  "$tg`: $(aws elbv2 describe-target-health --target-group-arn $arn --query 'TargetHealthDescriptions[].TargetHealth.State' --output text)"
}
```

`running == desired` for all 8 services and `healthy` for all 6 target groups confirms
the deployment and internal service discovery are both working.

### Initialize the MongoDB replica set (one-time, manual)

`rs.initiate()` is a genuine one-time admin action, deliberately **not** automated as a
Terraform `null_resource`/`local-exec` (that would race the ECS tasks' own health
checks at `apply` time - see `terraform/ecs.tf`'s comment on `aws_ecs_service.mongo_secondary`).
Run it after both `dtx-mongo-tg` and `dtx-mongo-secondary-tg` show `healthy` above.

First, the network config every one-off task below reuses. `ConvertTo-Json` on Windows
PowerShell 5.1 has a known bug where an array that came from `ConvertFrom-Json` gets
re-serialized as `{"value": [...], "Count": N}` instead of a plain JSON array (confirmed
by hitting it directly) - sidestep it entirely by building this one file from plain text
instead of an object graph:

```powershell
$nlb = terraform output -raw internal_nlb_dns_name
$databaseSg = terraform output -raw database_security_group_id
$internalSg = terraform output -raw internal_services_security_group_id

$subnetsRaw = terraform output -json private_subnet_ids
$privateSubnets = $subnetsRaw.Trim() -replace '[\[\]"]', '' -split ',\s*'
$subnetsJson = ($privateSubnets | ForEach-Object { "`"$_`"" }) -join ","
$netConfigJson = "{`"awsvpcConfiguration`":{`"subnets`":[$subnetsJson],`"securityGroups`":[`"$databaseSg`",`"$internalSg`"],`"assignPublicIp`":`"DISABLED`"}}"
$netConfigJson | Out-File -FilePath "$env:TEMP\rs-netconfig.json" -Encoding ascii -NoNewline
Get-Content "$env:TEMP\rs-netconfig.json"
```

Confirm that last line prints a real two-element `subnets` array (bare strings, no
`value`/`Count` wrapper) before continuing.

**`$nlb`, `$databaseSg`, `$internalSg` and the netconfig file only last for this
PowerShell session.** If you close and reopen the terminal (or start a new one) partway
through the steps below, re-run this block first - every one-off task command from here
on assumes these variables are already set. Hit this directly: running the later
`$evalScript` step in a session where `$nlb` was never set silently produces `":27017"`
instead of a real hostname rather than erroring.

**Step 1 - `rs.initiate()`.** Run it as a one-off Fargate task (reusing the secondary's
own already-pushed image and network path - no new Terraform resource, no persistent
cost) whose container command is the `mongosh --eval` call. Because the shell you're
admin-connecting *from* doesn't have to be the same address the replica set members
advertise themselves as, the one-off task dials the primary directly over the NLB (there's
no bastion/VPN into this VPC and `dtx-internal-nlb`'s DNS only resolves from inside it, so
`mongosh` can't run from your own machine) while still telling `rs.initiate()` to record
both members' *NLB* addresses as their identities - matching what dispatch-service and
every other client actually use to reach them:

```powershell
$evalScript = @"
rs.initiate({_id: "dtxrs", members: [
  {_id: 0, host: "$($nlb):27017"},
  {_id: 1, host: "$($nlb):27018"}
]})
"@

$overrides = @{
  containerOverrides = @(
    @{
      name    = "mongo"
      command = @("mongosh", "--host", $nlb, "--port", "27017", "--eval", $evalScript)
    }
  )
} | ConvertTo-Json -Depth 5
$overrides | Out-File -FilePath "$env:TEMP\rs-initiate-overrides.json" -Encoding ascii -NoNewline

aws ecs run-task --cluster dtx-cluster --task-definition dtx-mongo-secondary --launch-type FARGATE `
  --network-configuration "file://$env:TEMP\rs-netconfig.json" `
  --overrides "file://$env:TEMP\rs-initiate-overrides.json"
```

Wait ~30s, then check the one-off task's own log stream (it logs under the
`mongo-secondary` prefix, a new task ID distinct from the long-running secondary's) for
`"ok" : 1` in the command's output. Then confirm replica-set state the same way, swapping
the `--eval` value to
`"rs.status().members.map(m => ({name: m.name, stateStr: m.stateStr}))"` - expect one
`PRIMARY` and one `SECONDARY`.

If it fails with a connection error, the two target groups may not be fully healthy yet
(wait longer) or the security-group path is wrong (re-check `terraform/security-groups.tf`'s
`database` SG accepts 27017 from `internal_services`, which the one-off task's SGs above
already carry).

**Step 2 - apply the deferred schema setup.** The primary boots with `SKIP_INIT=true`
(`terraform/ecs.tf`) specifically because `db/mongo/init-telemetry.sh` can't write the
`telemetry`/`telemetry_history` collections until this node is actually primary - which
it only becomes after step 1. Re-run that same script now that it can succeed, as a
one-off task using the **primary's own** task definition (`dtx-mongo`, not the
secondary), overriding both its command (run the script directly instead of the normal
`mongod` entrypoint) and its environment (point it at the primary over the NLB, and flip
`SKIP_INIT` back off just for this one run - overriding a container's `environment` in
`run-task` only changes the named variables given, so leaving `SKIP_INIT` out of this
override would leave the baked-in `true` in effect):

```powershell
$overrides = @{
  containerOverrides = @(
    @{
      name    = "mongo"
      command = @("bash", "/docker-entrypoint-initdb.d/01-init-telemetry.sh")
      environment = @(
        @{ name = "MONGO_HOST"; value = $nlb },
        @{ name = "SKIP_INIT"; value = "false" }
      )
    }
  )
} | ConvertTo-Json -Depth 5
$overrides | Out-File -FilePath "$env:TEMP\rs-schema-overrides.json" -Encoding ascii -NoNewline

aws ecs run-task --cluster dtx-cluster --task-definition dtx-mongo --launch-type FARGATE `
  --network-configuration "file://$env:TEMP\rs-netconfig.json" `
  --overrides "file://$env:TEMP\rs-schema-overrides.json"
```

Check its log stream (`mongo/mongo/<new-task-id>`, under `/ecs/dtx-mongo`) for
`"driverless_taxi ready - telemetry ..."`. If it instead logs the `SKIP_INIT=true`
deferral message again, the `SKIP_INIT` override above didn't take - double check the
overrides file content before re-running.

### Verify replica-set reads and replication lag

Reuse the same `$env:TEMP\rs-netconfig.json` file from above (still valid - same
subnets/SGs) with a different `--eval`, run as another one-off task against the primary:

```powershell
$overrides = @{
  containerOverrides = @(
    @{
      name    = "mongo"
      command = @("mongosh", "--host", $nlb, "--port", "27017", "--eval",
                  "rs.printSecondaryReplicationInfo()")
    }
  )
} | ConvertTo-Json -Depth 5
$overrides | Out-File -FilePath "$env:TEMP\rs-lag-overrides.json" -Encoding ascii -NoNewline

aws ecs run-task --cluster dtx-cluster --task-definition dtx-mongo-secondary --launch-type FARGATE `
  --network-configuration "file://$env:TEMP\rs-netconfig.json" `
  --overrides "file://$env:TEMP\rs-lag-overrides.json"
```

Check that one-off task's log stream for the secondary's `syncedTo`/lag output. Near-zero
at idle is expected on this small dataset (see `terraform/README.md`'s open-risks note in
the 6.4HD report) - for a *meaningful* number, run it again during a burst of concurrent
`assignTrip` writes (a load test against `/rides`, see [`node-red/`](../node-red)).

For read distribution, dispatch-service's own CloudWatch logs are the simplest evidence:
with `readPreference=secondaryPreferred`, every successful `availableCandidates()` call
that reaches Mongo (i.e. a cache miss) is served by the secondary once it's up - there's
no per-query "which member served this" log line in the app today, so if you need that
distinction explicitly, `db.currentOp()` run against each member individually (swap
`--host $nlb --port 27017` for `27018` in the command above) shows which member is
actively handling read operations at the moment you sample it.

### Verify the API Gateway

Use `curl.exe` explicitly on Windows (PowerShell's `curl` alias is `Invoke-WebRequest`
and does not understand curl flags), and trim the invoke URL's trailing slash before
building paths with it:

```powershell
$BASE = (terraform output -raw http_api_invoke_url).TrimEnd('/')
curl.exe "$BASE/health"    # expect {"ok":true}
curl.exe "$BASE/nodes"     # expect the 21-node landmark list
```

`/rides` needs at least one vehicle with both a Postgres `status = 'available'` row and a
live position in Mongo `telemetry`, or have Node-RED running against the deployment.
Get Mosquitto's public IP (it's the one service with `assign_public_ip = true`, per
`terraform/ecs.tf`) and publish a telemetry packet directly, using the sedan shape from
[`db/mongo/sample-telemetry.json`](../db/mongo/sample-telemetry.json):

```powershell
$mosquittoTaskArn = aws ecs list-tasks --cluster dtx-cluster --service-name dtx-mosquitto --query "taskArns[0]" --output text
$mosquittoEni = aws ecs describe-tasks --cluster dtx-cluster --tasks $mosquittoTaskArn --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" --output text
$mosquittoIp = aws ec2 describe-network-interfaces --network-interface-ids $mosquittoEni --query "NetworkInterfaces[0].Association.PublicIp" --output text
$mosquittoIp

'{"vehicleID":"TAXI-001","vehicleType":"sedan","coordinates":{"lat":-37.8135637,"lon":144.9616326},"heading":275.4,"speed":0,"batteryLevel":90,"currentState":"parked","timestamp":1725000000000,"occupancy":{"seatsTotal":4,"seatsOccupied":0,"seatWeightKg":0},"doorsLocked":true}' |
  Out-File -FilePath "$env:TEMP\telemetry-taxi001.json" -Encoding ascii -NoNewline
docker run --rm -v "${env:TEMP}:/data" eclipse-mosquitto:2 mosquitto_pub -h $mosquittoIp -p 1883 -t "fleet/TAXI-001/telemetry" -f /data/telemetry-taxi001.json
Start-Sleep -Seconds 3
```

Confirm `$mosquittoIp` actually printed a real IP before publishing - an empty value
fails the `mosquitto_pub` silently rather than with an obvious error. Then request a ride:

```powershell
'{"userId":1,"pickup":"Camberwell","dropoff":"St Kilda","passengers":2}' |
  Out-File -FilePath "$env:TEMP\ride.json" -Encoding ascii -NoNewline
curl.exe -s -X POST "$BASE/rides" -H "content-type: application/json" -d "@$env:TEMP\ride.json"
```

Passing a JSON body to `curl.exe` with `-d '...'` directly (even single-quoted) gets
mangled by PowerShell's native-exe argument handling - always write it to a file first
and pass `-d "@file"`, as above; hit this directly (`{"error":"invalid JSON body"}`)
trying the inline form.

If it says `"no available vehicle seats N with a known position"` even after publishing
telemetry, the vehicle's Postgres `status` probably isn't `'available'` (e.g. left
`on_trip` by an earlier test session) - see the next section.

### Inspect or reset Postgres over the NLB

Needs `$nlb` and `$env:TEMP\rs-netconfig.json` from the "Initialize the MongoDB replica
set" section above - run that section's first code block first if you jumped straight
here (e.g. debugging vehicle status without touching Mongo this session).

Same problem as Mongo: no bastion into this VPC, so `psql` can't run from your own
machine either. Run it as a one-off task against the **primary's own** task definition,
reusing its already-injected `POSTGRES_PASSWORD` secret (`terraform/secrets.tf`) via a
shell wrapper so the password itself never has to be typed or fetched into your session:

```powershell
$pgCmd = "PGPASSWORD=`$POSTGRES_PASSWORD psql -h $nlb -p 5432 -U dtx -d driverless_taxi -c 'TABLE vehicles;'"
$overrides = @{
  containerOverrides = @(
    @{
      name    = "postgres"
      command = @("sh", "-c", $pgCmd)
    }
  )
} | ConvertTo-Json -Depth 5
$overrides | Out-File -FilePath "$env:TEMP\pg-check-overrides.json" -Encoding ascii -NoNewline

aws ecs run-task --cluster dtx-cluster --task-definition dtx-postgres --launch-type FARGATE `
  --network-configuration "file://$env:TEMP\rs-netconfig.json" `
  --overrides "file://$env:TEMP\pg-check-overrides.json"
```

Grab the task ID from the response, wait ~15s, then:

```powershell
aws logs get-log-events --log-group-name /ecs/dtx-postgres --log-stream-name "postgres/postgres/<new-task-id>" --query "events[].message" --output text
```

To reset a vehicle stuck `on_trip` from a previous test session back to `available`,
swap the `-c` argument for an `UPDATE` (note the escaped inner double quotes, needed
because this whole thing is itself inside a PowerShell double-quoted string):

```powershell
$pgCmd = "PGPASSWORD=`$POSTGRES_PASSWORD psql -h $nlb -p 5432 -U dtx -d driverless_taxi -c `"UPDATE vehicles SET status='available' WHERE vehicle_id IN ('TAXI-001','TAXI-002');`""
```

then rebuild `$overrides` and `run-task` exactly as above with a fresh overrides file.

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
VPC endpoints, the NLB, the API Gateway, and all 8 running Fargate tasks keep costing
money against the fixed, non-resetting Lab budget until they are actually destroyed.

If the Lab resets your whole account between sessions (some course configurations do
this), the local `terraform.tfstate` can go stale. Run `terraform plan` at the start of
a session too, not just before ending it, to catch drift early.

## Budget

With all 8 Fargate tasks running (steady state, no auto-scaling triggered), total cost
is roughly $0.28-0.29/hr (Redis's 256 CPU / 512 MB task and the Mongo secondary's 512
CPU / 1024 MB task - the same size as the primary - add to the base project's
$0.15-0.16/hr): Fargate vCPU/GB-hour pricing dominates, the VPC endpoints and
NLB add a small fixed idle cost, and SQS/CloudWatch stay effectively free at this demo's
message volume. Leaving it up overnight by accident is a few dollars, not a rounding
error, so `terraform destroy` matters every session.
