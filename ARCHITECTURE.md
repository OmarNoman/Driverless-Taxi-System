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
   either/or. Doesn't block Weeks 1-6, but needs a decision before Week 7. Proposed
   default: ECS Fargate.
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
   Only affects Week 8 (AWS networking), not Weeks 1-6. Proposed default: API Gateway
   serves the passenger-facing REST API; the MQTT broker has its own TLS-secured public
   endpoint for vehicle connections.

Items 1, 3 and 4 are resolved (Weeks 4, 6 and 2). Items 2 and 5 are Week 7-8 concerns and
did not block the Weeks 1-6 implementation.

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

## Note on version control

If `git commit` fails with a stuck `.git/index.lock` error, delete the stale lock file
(and any 0-byte temp files in `.git/`) and retry - this can happen after an interrupted
git operation.
