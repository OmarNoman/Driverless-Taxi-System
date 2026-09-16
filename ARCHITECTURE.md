# Architecture - finalized design (Week 1)

This document is the "finalize the system design" deliverable for Week 1 of the 1.2D
Plan. It restates the confirmed architecture from the plan in implementation terms, and
lists the decisions that are genuinely ambiguous in the plan text so they get made
deliberately instead of by accident once code is being written.

**The 1.2D Plan (`1.2D-Plan.pdf`) remains the source of truth.** This file exists to give
the code something more actionable than prose to be built against, and to record the
resolutions to the plan's open questions once they're made.

## Confirmed architecture (from the Plan's Solution Overview / Implementation Plan)

- **IoT edge (simulation):** Node-RED emulates each taxi's sensors and actuators (motor
  controller, door lock), publishing telemetry to and receiving commands from an MQTT
  broker. Payload fields depend on vehicle type (see revision D2 below). Dispatchable
  vehicles idle at a home node on the road graph and follow a node route when dispatched;
  the bus runs a fixed loop.
- **Messaging:** MQTT (publish/subscribe), chosen for low-bandwidth, low-latency,
  high-frequency IoT telemetry over traditional HTTP polling.
- **Event Router (Node.js):** consumes the raw MQTT telemetry stream, validates message
  payloads against the shared per-type schema, and re-publishes valid events onward.
- **Telemetry service (Node.js):** every 5 s (per the Plan) bulk-upserts the newest packet
  per vehicle into MongoDB `telemetry` (current state) and appends every packet to
  `telemetry_history` (append-only, TTL-pruned - see revision D1).
- **Dispatch service (Node.js):** on a ride request it filters available vehicles that can
  seat the party, runs A* over the Melbourne road graph (`graph/melbourne.json`) from each
  vehicle's nearest node to the pickup node, picks the lowest-cost one, writes the trip to
  PostgreSQL, and sends a dispatch command with the node route back through the broker.
- **Storage:** MongoDB for high-throughput telemetry (JSON documents, one current-state
  document per vehicle plus an append-only history); PostgreSQL for transactional data
  (user accounts, ride histories, billing, static fleet info) - chosen for ACID guarantees
  on ride bookings.
- **Edge-level filtering:** a stationary vehicle whose GPS delta is < 0.0001° between
  readings has its telemetry dropped before the broker, except one heartbeat packet every
  20 s so the Dispatch service still has a recent position and battery level.
- **Ordering/consistency:** every telemetry packet gets a Unix timestamp at the simulated
  edge; the `telemetry` write path drops any packet older than the current stored state
  (last-write-wins by timestamp, not by arrival order).
- **Scaling (Weeks 7-9, not yet built):** AWS Auto Scaling on the Telemetry and Event
  Router microservices, triggered by CPU utilization and MQTT queue depth via CloudWatch.

## Explicitly out of scope for this build

The Plan itself draws this line in its scalability discussion - restating it here so it
isn't accidentally implemented while chasing the breaking-point analysis:

- **MongoDB sharding** - discussed only as a theoretical response to a 5,000-vehicle
  breaking point; not part of the working prototype.
- **PostgreSQL read replicas** - same: theoretical future-scale mitigation, not built.
- **Clustered MQTT broker behind a load balancer** - same: theoretical, not built.

These stay as answers you can give if asked "how would this scale further," not as Week
1-6 (or even Week 7-9) deliverables.

## Open decisions (plan is ambiguous - flagging rather than assuming)

1. **MQTT broker software.** The Plan says "MQTT broker" / "Messaging Broker" but never
   names a product. **Resolved (Week 4): Eclipse Mosquitto**, chosen for being the
   lightweight industry-standard broker and close to what would run in the eventual AWS
   deployment. It runs locally as the `mosquitto` service in the repo-root
   `docker-compose.yml`, on `localhost:1883` with anonymous access (TLS and auth are
   Week 8 concerns).
2. **Week 7-8 compute target.** Implementation Plan says containers will be deployed via
   "Amazon Elastic Container Service **or** EC2 Auto Scaling Groups" - an unresolved
   either/or. **Resolved (Week 7): ECS Fargate**, chosen over EC2 Auto Scaling Groups
   because it needs no server patching/management, scales to zero cost once torn down,
   and bills per-second while tasks run - a better fit for a Learner Lab environment that
   gets built, tested, and destroyed repeatedly rather than kept running.
3. **How commuters receive ride status updates.** The Solution Overview's stakeholder
   requirements promise commuters "real-time status updates," but no week's task and
   neither diagram specifies the mechanism. **Resolved (Week 6): synchronous only.** The
   `POST /rides` endpoint returns the assigned vehicle ID and ETA in its HTTP response;
   no live push or polling was built. A real-time channel would be future work.
4. **Sensor list mismatch.** Solution Overview lists GPS, battery voltage monitor,
   speedometer. Implementation Plan adds a seat-weight sensor. Resolution: Week 2 will
   simulate the union of both (GPS, battery, speedometer, seat-weight).
5. **Public-subnet ingestion wording.** Implementation Plan's cloud section says "an AWS
   API Gateway and an MQTT will be exposed in the public subnet" - unclear phrasing.
   **Resolved (Week 7):** the Mosquitto broker sits in the VPC's public subnet (the same
   role it plays locally, reachable directly by the vehicle simulator); the three Node.js
   services and both databases sit in private subnets; the passenger-facing REST API
   (Dispatch service) is reached via API Gateway rather than being exposed directly. The
   API Gateway resource itself is a Week 8 build item (see "Week 7 - containerisation and
   cloud prep" below for why), but the subnet design this decision requires is built now.

Items 1, 2, 3, 4 and 5 are all resolved. Items 2 and 5 only started mattering from Week 7
onward and did not block the Weeks 1-6 implementation.

## Revisions after the Weeks 1-6 review

A review compared the build against the plan and flagged four deviations. Each was
discussed and resolved with the user, then applied as a revision pass across Weeks 2-6.

### D1 - telemetry storage: current state and history

The plan calls the telemetry store "time-series" (p3, p5) but its own consistency rule
(p6) says to "drop packets that have older timestamps than the current ones" - which is a
current-state model, not append-only. Resolution: keep both.
- `telemetry` - one document per vehicle, upserted, last-write-wins. Read by Dispatch.
- `telemetry_history` - append-only, one document per received packet, for trajectory and
  aggregate queries. TTL index on `ingestedAt` prunes it after `HISTORY_TTL_DAYS` (7).
  Written by the Telemetry service in the same 5 s flush; no validator.

### D2 - per-vehicle-type telemetry payloads

The plan (p3) wants "different vehicle types ... with different sensor configurations and
payload structures." `schema/telemetry.schema.json` is now a `oneOf` of three fully
specified branches. Common fields: `vehicleID`, `vehicleType`, `coordinates`, `heading`,
`speed`, `batteryLevel`, `currentState` (driving | parked | charging), `timestamp`.
Type-specific:
- **sedan** - `occupancy{seatsTotal,seatsOccupied,seatWeightKg}`, `doorsLocked`
- **van** - `occupancy{...}`, `doorState{front,slidingLeft,rear}`, `cargoLoadKg`
- **bus** - `passengerCount`, `passengerCapacity`, `doorState{front,middle,rear}`,
  `wheelchairRampDeployed`, `nextStopId`

The fleet is one of each (TAXI-001 sedan, TAXI-002 van, TAXI-003 bus). Dispatch applies a
hard capacity filter (`passenger_seats >= passengers`) plus a gentle right-size
preference. The bus runs a fixed route and is never a dispatch candidate (its Postgres
`status` stays `on_trip`).

### D3 - A* over the provided Melbourne road graph

`graph/melbourne.json` (21 suburb nodes, 36 undirected edges, from the user-supplied
network) is the single source of truth, loaded by the Dispatch service and by Node-RED
via `settings.js`. A* is now real graph search: edge cost = Haversine km between endpoints,
heuristic `h(n)` = Haversine to the goal node. A ride request names the pickup and dropoff
**nodes** by name (`{ userId, pickup, dropoff, passengers }`); the response carries the
suburb route and the dispatch command carries the node-id route, which the simulated
vehicle then drives.

### D4 - test framework

The plan says "a framework like Jest"; the services use Node's built-in `node --test`.
Kept: it ships with Node, runs the native-ESM services with no config or extra
dependencies, and the units under test are simple (pure functions, one class with an
injected fake). Jest would add ergonomic mocking and snapshots; it would be revisited only
if later integration testing needs them, and via a root workspace rather than three
copies.

## Week 7 - containerisation and cloud prep

Plan says (Project Plan, Week 7): "Package the microservices into Docker containers.
Design the AWS VPC, defining public and private subnets for the IoT ingestion and
internal service layers respectively." This week produces buildable Docker images and
the Terraform-defined AWS networking + container registry Week 8 deploys onto - no
running containers in AWS, no SQS, no auto-scaling, no IAM roles, those are Week 8.

**Deployment target is an AWS Academy Learner Lab account**, which shapes this design in
two concrete ways beyond the plan's own wording: it cannot create IAM roles or policies
(any role Week 8 needs must be an existing `LabRole`, looked up via a Terraform `data`
source, never created), and its budget is fixed for the whole course rather than
resetting per session, so the design favours cheap-to-run, trivial-to-tear-down over
production-grade HA.

- **Dockerfiles** (`services/*/Dockerfile`, `node:22-alpine`): `event-router` and
  `dispatch-service` each need a file from outside their own directory
  (`schema/telemetry.schema.json`, `graph/melbourne.json` respectively), so their build
  context is the repo root, and each bakes the resolved path in as `ENV
  SCHEMA_PATH=...`/`ENV GRAPH_PATH=...`, both already-overridable env vars in the
  existing code, so no application code changed. `telemetry-service` needs no outside
  file and builds from its own directory. All three run `CMD ["node", "src/index.js"]`
  rather than `npm start`, since `npm` does not forward `SIGTERM` to the child process,
  which would otherwise silently break the graceful-shutdown handlers all three services
  already implement once ECS starts stopping tasks in Week 8. Connection strings
  (`MQTT_URL`, `PG_URL`, `MONGO_URL`, `HTTP_PORT`) stay supplied at run time, never baked
  into an image layer.
- **VPC** (`terraform/vpc.tf`, `10.20.0.0/16`): one public subnet (Mosquitto only) and
  one private subnet (the three services plus both databases, tier isolation enforced by
  security groups rather than separate subnets), across `var.az_count` availability
  zones, defaulted to **1** rather than the usual 2, since the 3 interface VPC endpoints
  bill per-AZ and this environment is torn down after every test session rather than run
  for real HA to matter. A one-line variable change restores multi-AZ if the final report
  needs to demonstrate it.
- **No NAT Gateway, by design, permanently.** Private-subnet resources reach AWS
  services through **VPC endpoints** instead (`terraform/vpc-endpoints.tf`): a free S3
  gateway endpoint (ECR stores image layers in S3) plus interface endpoints for
  `ecr.api`, `ecr.dkr`, and `logs`. This avoids NAT's non-trivial hourly cost and the low
  Elastic IP quota Academy accounts typically have. Trade-off: Week 7 can only confirm
  these endpoints exist and are correctly configured; proving a private-subnet Fargate
  task can actually pull an image through them is a Week 8 concern, since no task runs
  here yet.
- **Security groups** (`terraform/security-groups.tf`): Mosquitto's is open on 1883 to
  the internet; the database SG accepts 5432/27017 only from the internal-services SG;
  the internal-services SG has **no ingress rule yet**, since none of the three services
  listen on a port Week 7 has a caller for (Dispatch's port-8080 ingress source depends
  on whether Week 8 fronts it with a VPC Link/NLB or an ALB, a decision that belongs to
  Week 8 once something is actually running behind it).
- **Container registry** (`terraform/ecr.tf`): one ECR repository per Node.js service,
  `force_delete = true` on each so `terraform destroy` never fails on a repo still
  holding an image. Mosquitto gets no repository, it pulls `eclipse-mosquitto:2` straight
  from Docker Hub via its public subnet's direct internet egress.
- **No API Gateway resource this week**, a deliberate scope call, not an oversight: its
  only useful backend integration (a VPC Link to a private Fargate service) does not
  exist until Week 8 stands up the actual ECS service, so an empty API Gateway shell has
  nothing to validate against, which would break this project's pattern of pairing every
  deliverable with a concrete, observable check.
- **Terraform state is local**, no S3/DynamoDB backend, appropriate for a solo student
  project that gets rebuilt from scratch each session rather than shared with a team.

## Week 8c - API Gateway and auto-scaling

Plan says (Implementation Plan): "Using an AWS API Gateway and [the] MQTT [broker] will
be exposed in the public subnet to securely ingest data and route external requests,"
and (Solution Overview / Project Plan, Week 8): the Node.js microservices "utilize AWS
auto scaling," monitoring "CPU utilization and message queue depth," spinning up
"additional instances of the Telemetry and Event Router microservices" when a threshold
is exceeded, scaling back down once traffic subsides. Built in three independently
committed sub-parts (8c-i/ii/iii), the same pattern used for Week 8.

**8c-i - API Gateway + VPC Link (`terraform/api-gateway.tf`):** a public regional HTTP
API (protocol_type `HTTP`) with an `aws_apigatewayv2_vpc_link` doing a private
`HTTP_PROXY` integration into the existing internal NLB's `dispatch_service` listener
(`terraform/nlb.tf`, registered back in Week 8b specifically for this). No new VPC
endpoint needed: this is a *public* API (not the `PRIVATE` endpoint type), so it runs on
AWS-managed infrastructure outside the VPC - an `execute-api` endpoint only matters for a
private API called from inside a VPC, and the VPC Link's own ENIs reach the NLB over the
VPC's local route, already open via the `vpc_link`/`internal_services` security groups.
Three explicit routes (`GET /health`, `GET /nodes`, `POST /rides`) rather than a single
`ANY /{proxy+}` catch-all, since dispatch-service has exactly those three routes and no
path parameters - an unrecognized method/path is rejected at the API Gateway edge instead
of being forwarded through. `$default` auto-deploy stage, no named stage: no CI/CD or
staged-rollout requirement anywhere in the plan, and this project's AWS lifecycle is
apply-verify-destroy within one sitting.

**Prerequisite found while building this:** `var.az_count` had to go from 1 to 2.
AWS's HTTP API VPC Link requires subnets spanning at least 2 Availability Zones, and
`terraform/terraform.tfvars` had `az_count = 1` (a single private subnet) since Week 7 -
exactly the "single line change" `variables.tf`'s own comment already anticipated for a
multi-AZ demonstration, just triggered here by a hard technical requirement rather than a
report-writing choice.

Confirmed working end to end against the live account: `GET /health`, `GET /nodes`, and
`POST /rides` (once a vehicle has a known position) all return the same responses
already proven directly against the NLB in Week 8b, now reachable from a public HTTPS
URL. One operational quirk found and confirmed, not a config bug: requests to the
invoke URL intermittently return `{"message":"Service Unavailable"}`. A 30-request
rapid-fire burst against `/health` showed roughly half failing throughout, with no
convergence toward reliable success even by the end of the burst - ruling out an
earlier, weaker "one-time cold start" theory. Confirmed not the backend at the same
time: the dispatch-service NLB target stayed `healthy` and its ECS service stayed at a
stable `desired == running`. This points at the VPC Link's own dynamically-scaling
network capacity behaving unreliably at the low, sporadic request volumes manual
testing produces, not at anything in this project's Terraform config - there is
nothing here that controls that scaling directly. See `terraform/README.md`'s "Common
errors" for the practical workaround (retry - each request has roughly even odds
independent of the last one's result).

**8c-ii - event-router's MQTT fan-out (`terraform/ecs.tf`, event-router's `environment`
block):** found while planning the auto-scaling sub-part (8c-iii): event-router
subscribes to a *plain* MQTT topic filter (`fleet/+/telemetry`), and plain MQTT fans
every message out to every subscriber. Scaling event-router past 1 instance would have
made every instance receive and process every telemetry packet independently -
duplicate SQS sends, duplicate `telemetry_history` writes - not a load split. This had
never mattered before since it only ever ran as a fixed single instance. Fixed by
switching the subscribe filter to a shared subscription:
`TOPIC_IN=$share/event-router/fleet/+/telemetry`. This required **zero application code
changes** - `TOPIC_IN` was already an environment variable
(`services/event-router/src/index.js`), used only as the `subscribe()` filter; the
`message` handler receives the broker-delivered *publish* topic regardless of the
subscribe-side filter, so downstream vehicleID parsing is unaffected. Mosquitto 2.x
supports `$share/` natively with no plugin and no ACL involvement, confirmed against
both the local anonymous config and the AWS task's equivalent inline config. Confirmed
locally with two instances and a 200-message burst: before the fix both instances'
`received` stats landed at 200 (duplicate fan-out - the bug is real); after, the two
summed to 200 (100/100 in the observed run), split between them with nothing dropped.

**8c-iii - CloudWatch alarms + Application Auto Scaling
(`terraform/autoscaling.tf`):** Step Scaling policies driven by explicit CloudWatch
alarms, for both CPU and SQS queue depth, chosen over Target Tracking because the
plan's own wording is threshold-crossing language ("if X exceeds a set threshold, spin
up additional instances... scaling back down when traffic subsides") - a near 1:1
translation to "alarm breaches threshold -> step policy adds capacity," and each step
is individually inspectable in CloudWatch for Week 9's evidence. Target Tracking has
no predefined ECS metric for SQS depth; doing it "properly" needs a metric-math-derived
"backlog per task" customized metric, exactly the kind of custom/derived metric already
avoided by choosing `ApproximateNumberOfMessagesVisible` (the correct CloudWatch metric
name for what the SQS API attribute `ApproximateNumberOfMessages` reports) in the first
place - a free, standard, non-custom metric.

**Deliberate deviation from the plan's literal wording:** the plan names both "the
Telemetry and Event Router microservices" for scaling on queue depth. event-router only
ever *writes* to `dtx-telemetry-queue` in AWS mode - it never reads from or drains it;
only telemetry-service (the consumer) does. Scaling event-router in response to queue
depth would not mechanically relieve a backed-up queue, so **event-router scales on CPU
only here; telemetry-service scales on both CPU and queue depth.** This is a conscious,
explained departure from the plan's literal wording, not a silent one - made because
the mechanically correct design was judged more defensible than literal compliance with
a requirement that would not do what it says. CPU thresholds: 70% (2 min) to scale out,
30% (3 min) to scale in, on both services. Queue-depth thresholds on telemetry-service:
100 messages (2 min) to scale out, 10 (3 min) to scale in - Week 9's load tests run
10/100/500 vehicles at 1s intervals, and telemetry-service's 5-second batch flush should
keep normal-load queue depth in the single digits, so 100 sustained is comfortably above
the noise floor while reachable once load is heavy enough to matter. Both
`aws_ecs_service.event_router` and `aws_ecs_service.telemetry_service` needed
`lifecycle { ignore_changes = [desired_count] }` added (`terraform/ecs.tf`) - without
it, a `terraform plan`/`apply` run while auto-scaled out would see the live desired
count as drift from the hardcoded `1` and silently force it back down.

Confirmed working end to end against the live account, with a genuine (not synthetic)
CloudWatch-driven scale-out and scale-in: `aws cloudwatch set-alarm-state` was tried
first as a quick demo shortcut and found unreliable - it changes an alarm's displayed
state but does not dependably invoke the associated Application Auto Scaling policy, so
it is not used anywhere in this project's verification steps (see `terraform/README.md`
"Common errors"). The technique that does work: temporarily lowering
`telemetry_service_cpu_high`'s threshold below telemetry-service's real, currently-
observed idle CPU (~0.2-0.25%) causes a genuine CloudWatch evaluation to cross it within
2-3 minutes. Result: `dtx-telemetry-service` climbed from `desired: 1` to `desired: 3`
(the configured `max_capacity`), then settled back to `desired: 1, running: 1` a few
minutes after the threshold was reverted, once the already-armed `cpu_low` alarm (30%
threshold, comfortably above real idle CPU) fired.

## Note on version control

If `git commit` fails with a stuck `.git/index.lock` error, delete the stale lock file
(and any 0-byte temp files in `.git/`) and retry - this can happen after an interrupted
git operation.
