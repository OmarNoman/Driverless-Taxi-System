# Driver-less Taxi System for a Smart City

SIT314 (Software Architecture and Scalability for IoT) Distinction project - a scalable,
event-driven IoT platform for managing a fleet of simulated driverless taxis.

This repository is the implementation of the 1.2D Project Plan, built over nine weeks
from local prototype through to a fully deployed, auto-scaling AWS system, and load
tested at up to 500 simulated vehicles.

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

In AWS, the passenger-facing side is fronted by an API Gateway HTTP API (with a VPC Link
into the private subnet), and event-router and telemetry-service both auto-scale on
CloudWatch alarms: CPU utilisation for event-router, CPU and SQS queue depth for
telemetry-service.

## Project layout

```
driverless-taxi-system/
├── docker-compose.yml   local infra: postgres, mongo, mosquitto
├── schema/              telemetry.schema.json - shared per-vehicle-type payload contract
├── graph/               melbourne.json - road network for A* dispatch + route following
├── node-red/            local Node-RED project (IoT edge simulation + load-test tooling)
├── db/
│   ├── postgres/          schema.sql + seeds (+ Dockerfile: same, baked in for AWS)
│   └── mongo/              init-telemetry.sh (+ Dockerfile: same, baked in for AWS)
├── broker/               Mosquitto config (local only; AWS writes an equivalent config
│                         inline in the ECS task definition, see terraform/ecs.tf)
├── terraform/            AWS VPC, registry, ECS deployment, API Gateway, auto-scaling
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
  DNS names.
- A public API Gateway HTTP API with a VPC Link fronting dispatch-service, so ride
  requests can be made over HTTPS from outside the VPC.
- CloudWatch alarms and AWS Application Auto Scaling on event-router (CPU) and
  telemetry-service (CPU and SQS queue depth), scaling each between 1 and 3 tasks.
- Credentials (the Postgres password and connection string) stored in AWS SSM Parameter
  Store as `SecureString` parameters rather than plaintext Terraform variables.
- 5 ECR repositories (one per Node.js service, one each for the custom-seeded
  Postgres/Mongo images).

This has been proven working end to end against a real account: all 6 services reach
`running == desired`, a live MQTT publish through Mosquitto's public IP flows all the way
through event-router, SQS, and telemetry-service into MongoDB, and a sustained 500-vehicle
load test genuinely triggered CloudWatch alarms and auto-scaled both event-router and
telemetry-service.

Full setup (AWS Academy Learner Lab credential workflow and the exact build/push/apply/
verify commands) is in [`terraform/README.md`](./terraform/README.md). Two things worth
knowing before you open that file:

- **`terraform apply` needs a live AWS Academy Learner Lab session** - temporary
  credentials that expire every few hours, re-exported each session.
- **`terraform destroy` is mandatory at the end of every AWS session, not optional.**
  Nothing stops billing just by closing the Lab tab; only destroying the resources does.

## Version control

If `git commit` ever fails with a stuck `.git/index.lock` error, delete that file (and
any 0-byte temp files in `.git/`) and retry - this happens after an interrupted git
operation.
