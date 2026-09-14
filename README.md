# Driver-less Taxi System for a Smart City

SIT314 (Software Architecture and Scalability for IoT) Distinction project - a scalable,
event-driven IoT platform for managing a fleet of simulated driverless taxis.

This repository is the implementation of the **1.2D Project Plan**, which is the single
source of truth for scope, requirements, and the week-by-week build order. See:

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) - finalized system design, confirmed decisions,
  and open decisions still needing a call.
- [`ROADMAP.md`](./ROADMAP.md) - the week-by-week implementation plan, mapped directly to
  the 1.2D Plan, with dependencies and validation criteria for each week.

## Status

Weeks 1-6 done: the full request-to-dispatch loop runs locally - edge simulation, data
layer, MQTT ingestion, the batching Telemetry service, and the Dispatch service. A
post-review revision added per-vehicle-type telemetry, an append-only telemetry history,
and A* routing over a real Melbourne road graph (see `ARCHITECTURE.md`).

Week 7 added a `Dockerfile` per service and a Terraform-defined AWS VPC + container
registry. Week 8 (split into 8a/8b/8c, built one piece at a time) has containerised the
databases and wired an SQS buffer (8a), and deployed the whole system to AWS as 6 running
ECS Fargate services with that SQS buffer proven working end to end (8b). API Gateway and
CloudWatch auto-scaling (8c) and Week 9's load testing are not started. See
[`ROADMAP.md`](./ROADMAP.md).

## How it works

Two flows, both event-driven, both flowing through MQTT:

**Telemetry (edge to database).** Node-RED simulates the fleet (one sedan, one van, one
bus) and publishes a per-vehicle-type telemetry payload on `fleet/<id>/telemetry`
whenever something changes. `event-router` subscribes, validates each payload against the
shared schema (`schema/telemetry.schema.json`, one Ajv `oneOf` covering all three vehicle
types), and republishes valid packets on `validated/<id>/telemetry` (and, when deployed to
AWS, also onto an SQS queue - the plan's buffer "between the MQTT broker and the
database"). `telemetry-service` consumes that stream, batches it in memory, and every 5
seconds bulk-upserts the newest reading per vehicle into MongoDB `telemetry` (current
state) while appending every reading to `telemetry_history` (an append-only trajectory
log). In SQS mode, a message is only deleted from the queue once its batch has actually
landed in Mongo, not the moment it's received, so a mid-batch crash can't silently lose
data.

**Dispatch (passenger to vehicle).** A passenger calls `POST /rides` on `dispatch-service`
naming a pickup and dropoff by landmark name. It filters Postgres for available vehicles
with enough seats, runs A* (`services/dispatch-service/src/graph.js`) over the real
Melbourne road graph (`graph/melbourne.json`) from each candidate's last known position to
the pickup node, and picks the lowest-scoring one (road distance plus a battery and a
right-size penalty). It writes the trip to Postgres and flips the vehicle to `on_trip` in
one transaction, publishes a `dispatch` command with the node route to
`fleet/<id>/command`, and returns the assignment synchronously. Node-RED's simulated
actuator picks up that command and drives the vehicle along the route.

Everything is stateless and reconnects on its own; there's no service that has to start
before another for the system to eventually converge.

## Project layout

```
driverless-taxi-system/
├── ARCHITECTURE.md      finalized design + open decisions + post-review revisions
├── ROADMAP.md           week-by-week plan, traced to the 1.2D Plan
├── docker-compose.yml   local infra: postgres, mongo, mosquitto
├── schema/              telemetry.schema.json - shared per-vehicle-type payload contract
├── graph/               melbourne.json - road network for A* dispatch + route following
├── node-red/            local Node-RED project (IoT edge simulation)
├── db/
│   ├── postgres/          schema.sql + seeds (+ Dockerfile: same, baked in for AWS)
│   └── mongo/              init-telemetry.sh (+ Dockerfile: same, baked in for AWS)
├── broker/               Mosquitto config (local only; AWS writes an equivalent config
│                         inline in the ECS task definition, see terraform/ecs.tf)
├── terraform/            AWS VPC, registry, and (from 8b) the running ECS deployment
└── services/
    ├── event-router/       validates the MQTT telemetry stream (+ Dockerfile)
    ├── telemetry-service/   batches the validated stream into MongoDB (+ Dockerfile)
    └── dispatch-service/    ride requests -> A* nearest vehicle -> MQTT command (+ Dockerfile)
```

The simulated fleet is one sedan (TAXI-001), one van (TAXI-002) and one bus (TAXI-003).
Sedans and vans are dispatchable and drive graph routes; the bus runs a fixed loop.

## Running it locally

Start the databases and MQTT broker:

```bash
docker compose up -d
```

Start the Node-RED simulation:

```bash
cd node-red
npm install
npm start
```

The Node-RED admin UI is at http://127.0.0.1:1880/. Flows live in
`node-red/flows.json` (not the global `~/.node-red`), so the simulation is
version-controlled with the rest of the code.

Start the services, each in its own terminal:

```bash
cd services/event-router && npm install && npm start
```

```bash
cd services/telemetry-service && npm install && npm start
```

```bash
cd services/dispatch-service && npm install && npm start
```

dispatch-service listens on port 8080 by default; if that's already taken on your
machine, set `HTTP_PORT` to something else, e.g. `HTTP_PORT=8090 npm start`.

Then request a ride. Pickup and dropoff are named road-graph nodes (`GET /nodes` lists
them); the demo passenger has id 1:

```bash
curl -s -XPOST localhost:8080/rides -H 'content-type: application/json' \
  -d '{"userId":1,"pickup":"Camberwell","dropoff":"St Kilda","passengers":2}'
```

(use whatever port you started dispatch-service on). The response carries the assigned
vehicle, ETA and the suburb route; the vehicle then drives that route on the Node-RED map.

Each component has its own README with details and checks:
[`db/`](./db/README.md), [`event-router/`](./services/event-router/README.md),
[`telemetry-service/`](./services/telemetry-service/README.md),
[`dispatch-service/`](./services/dispatch-service/README.md).

## Deploying to AWS

Each service (plus custom-seeded Postgres and Mongo images) builds as a Docker image, and
[`terraform/`](./terraform/README.md) provisions and runs the whole system on AWS:

- A VPC with a public subnet for Mosquitto (vehicles need to reach it directly) and a
  private subnet for the three Node.js services and both databases, VPC endpoints instead
  of a NAT Gateway.
- All 6 things (event-router, telemetry-service, dispatch-service, Postgres, Mongo,
  Mosquitto) running as ECS Fargate services.
- An SQS queue (with a dead-letter queue) as the buffer between the broker and the
  database, feeding telemetry-service.
- An internal Network Load Balancer for service-to-service discovery. This is a
  deliberate substitution: AWS Cloud Map is entirely blocked in the AWS Academy Learner
  Lab account this was built and tested against, so the three Node.js services reach
  Postgres/Mongo/Mosquitto via `<internal-nlb-dns-name>:<port>` instead of per-service
  DNS names. See `terraform/README.md`'s "Cloud Map is blocked in this account" note.
- 5 ECR repositories (one per Node.js service, one each for the custom-seeded
  Postgres/Mongo images).

Not yet built: the API Gateway resource in front of dispatch-service and the
CloudWatch/Application Auto Scaling policies (both Week 8c), and the escalating load test
(Week 9).

This has been proven working end to end against a real account: all 6 services reach
`running == desired`, and a live MQTT publish through Mosquitto's public IP was confirmed
to flow all the way through event-router, SQS, and telemetry-service into MongoDB.

Full setup (AWS Academy Learner Lab credential workflow, exact build/push/apply/verify
commands, and a running list of environment-specific gotchas actually hit and fixed while
building this) is in [`terraform/README.md`](./terraform/README.md). Two things worth
knowing before you open that file:

- **`terraform apply` needs a live AWS Academy Learner Lab session** - temporary
  credentials that expire every few hours, re-exported each session.
- **`terraform destroy` is mandatory at the end of every AWS session, not optional.**
  Nothing stops billing just by closing the Lab tab; only destroying the resources does.

## Version control

If `git commit` ever fails with a stuck `.git/index.lock` error, delete that file (and
any 0-byte temp files in `.git/`) and retry - this happens after an interrupted git
operation.
