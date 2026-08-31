# Week 1-6 Implementation Roadmap

Traced directly to the 1.2D Plan's "Project Plan" section (week-by-week list) and
"Solution Overview" / "Implementation Plan" sections (feature detail). Each week is only
started once the previous week's validation has passed. See `ARCHITECTURE.md` for the
open decisions referenced below.

## Week 1 — Architecture & Edge Setup

- **Plan says (Project Plan, Week 1):** "Finalize the system design, initialize version
  control (GitHub), and configure the local Node-RED development environment."
- **Tasks:** create the repo, `.gitignore`, `README.md`; write `ARCHITECTURE.md`
  capturing the confirmed design and flagging open decisions; install Node-RED as a
  project-local dependency with its own `userDir` so flows are version-controlled.
- **Depends on:** nothing (first week).
- **Deliverable:** a git repository with an initial commit, and a working local
  Node-RED instance.
- **Validation:** `git log` shows the initial commit; `npm start` in `node-red/` brings
  up the Node-RED admin UI at `http://127.0.0.1:1880/`.
- **Explicitly not doing yet:** no Node-RED flows, no services, no databases — those are
  later weeks' deliverables.

## Week 2 — IoT Simulation

- **Plan says (Project Plan, Week 2):** "Build the Node-RED flow to simulate the
  autonomous taxi fleet. Implement virtual sensors (GPS, battery) and actuators,
  ensuring the payload structure is optimized for MQTT transmission."
- **Tasks:** Node-RED flow(s) simulating one or more taxis, generating GPS, battery,
  speedometer, and seat-weight sensor readings (union of the two sensor lists in the
  Plan — see `ARCHITECTURE.md` open decision #4) on an interval; simulated actuators
  (motor controller, door lock) that react to an incoming command message; JSON payload
  shape matches what Telemetry/Dispatch will consume later (`vehicleID`, `coordinates`,
  `speed`, `batteryLevel`, `currentState`, `timestamp`). Apply the Plan's edge-level
  filter (drop a reading if parked and GPS delta < 0.0001°).
- **Depends on:** Week 1 (Node-RED environment).
- **Deliverable:** `node-red/flows.json` simulating the fleet, viewable/runnable in the
  Node-RED editor.
- **Validation:** Debug/inject nodes show correctly-shaped telemetry payloads being
  generated on an interval, and confirm the parked-vehicle filter suppresses unchanged
  readings.
- **Explicitly not doing yet:** no live MQTT connection required this week — the broker
  doesn't exist until Week 4, so payload generation is validated via Node-RED's own
  debug output, not an end-to-end publish.

## Week 3 — Data Layer Implementation

- **Plan says (Project Plan, Week 3):** "Provision the local development databases.
  Construct the relational schema in PostgreSQL for ride/user management and configure
  the MongoDB document structure for high-throughput telemetry ingestion."
- **Tasks:** local PostgreSQL instance with a schema covering user accounts, ride
  histories, billing statuses, and static fleet information (per Implementation Plan);
  local MongoDB instance with a validated document shape for telemetry (per the same
  section: timestamp, vehicleID, coordinates, speed, battery level, current state).
- **Depends on:** nothing from Weeks 1-2 directly (can start independently), but Weeks 5
  and 6 depend on this.
- **Deliverable:** `db/postgres/schema.sql` (or migration files) and `db/mongo/` schema
  validation config.
- **Validation:** schema applies cleanly to a fresh local Postgres database; a sample
  telemetry document validates against the Mongo schema.
- **Explicitly not doing yet:** no MongoDB sharding, no PostgreSQL read replicas — both
  are explicitly out of scope per the Plan's own scalability discussion.

## Week 4 — Ingestion & Messaging

- **Plan says (Project Plan, Week 4):** "Deploy the MQTT broker. Develop the initial
  Node.js Event Router to consume the raw vehicle telemetry stream and validate message
  payloads."
- **Tasks:** stand up a local MQTT broker (default: Mosquitto — see `ARCHITECTURE.md`
  open decision #1, needs confirmation); `services/event-router` Node.js service that
  subscribes to the vehicle telemetry topic(s), validates incoming payloads against the
  Week 3 Mongo schema shape, and rejects/logs malformed messages. Wire Week 2's Node-RED
  simulation to actually publish to this broker.
- **Depends on:** Week 2 (simulated telemetry to consume), Week 3 (payload shape to
  validate against).
- **Deliverable:** a running broker plus `services/event-router`, with Node-RED
  publishing real MQTT messages the router receives.
- **Validation:** starting the Node-RED simulation and the Event Router together shows
  telemetry flowing end-to-end (visible in Event Router logs), with malformed test
  messages correctly rejected.
- **Explicitly not doing yet:** no broker clustering/load balancing (out of scope, see
  `ARCHITECTURE.md`); the Event Router validates and passes messages on, it does not yet
  write to a database — that's Week 5.

## Week 5 — Microservices: Telemetry

- **Plan says (Project Plan, Week 5):** "Develop the Node.js Telemetry microservice
  using asynchronous event loops. Implement the batching logic to efficiently write the
  filtered stream data into MongoDB."
- **Tasks:** `services/telemetry-service` consumes validated events from the Event
  Router, batches state updates over a 5-second window (per the Plan), and performs bulk
  inserts/upserts into MongoDB using the Week 3 schema. Fully asynchronous — the
  ingestion path must not block on DB I/O (per the Plan's Problem Description).
- **Depends on:** Week 3 (Mongo schema), Week 4 (Event Router producing validated
  events).
- **Deliverable:** `services/telemetry-service`, persisting simulated fleet telemetry
  into MongoDB.
- **Validation:** running the full simulation → broker → Event Router → Telemetry
  Service chain results in vehicle state documents appearing/updating in MongoDB, with
  writes occurring in ~5-second batches rather than per-message.
- **Explicitly not doing yet:** no dispatch logic (Week 6); no AWS/CloudWatch-based
  auto-scaling (Weeks 7-8).

## Week 6 — Microservices: Dispatch

- **Plan says (Project Plan, Week 6):** "Develop the Node.js Dispatch microservice.
  Implement the routing algorithm to calculate the nearest available vehicle and send
  dispatch commands back to the Node-RED actuators via the MQTT broker."
- **Tasks:** `services/dispatch-service` exposes a ride-request entry point; filters
  currently-available vehicles from PostgreSQL/Mongo state; ranks candidates using the
  Haversine formula and the A* heuristic (per the Plan) to select the optimal vehicle;
  writes the resulting trip record to PostgreSQL; publishes a dispatch command to the
  vehicle's MQTT command topic. Per `ARCHITECTURE.md` open decision #3, the ride-request
  call returns the assigned vehicle ID and ETA synchronously in its response — this is
  the only passenger-facing status mechanism built in Weeks 1-6, since nothing further
  is specified in this week's task.
- **Depends on:** Week 3 (Postgres schema for trips/vehicles), Week 4 (broker to publish
  commands on), Week 2 (simulated actuators to receive and react to the command).
- **Deliverable:** `services/dispatch-service`, completing the request → nearest-vehicle
  → command loop.
- **Validation:** submitting a simulated ride request results in the correct nearest
  available vehicle being selected, a trip record written to PostgreSQL, a command
  published to that vehicle's topic, and the Node-RED actuator simulation visibly
  reacting to it.
- **Explicitly not doing yet:** no live/ongoing passenger status push beyond the initial
  synchronous response (flagged as an open decision, not assumed); no containerization
  or cloud deployment (Weeks 7-8); no load testing (Week 9).

## Weeks 7-9 (not in this implementation pass)

Containerization/cloud prep (7), AWS deployment & auto-scaling (8), and load
testing/final reporting (9) are out of scope for this Week 1-6 implementation pass, per
the current instruction. Open decisions #2 and #5 in `ARCHITECTURE.md` need resolving
before Week 7 starts.
