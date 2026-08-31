# Architecture - finalized design (Week 1)

This document is the "finalize the system design" deliverable for Week 1 of the 1.2D
Plan. It restates the confirmed architecture from the plan in implementation terms, and
lists the decisions that are genuinely ambiguous in the plan text so they get made
deliberately instead of by accident once code is being written.

**The 1.2D Plan (`1.2D-Plan.pdf`) remains the source of truth.** This file exists to give
the code something more actionable than prose to be built against, and to record the
resolutions to the plan's open questions once they're made.

## Confirmed architecture (from the Plan's Solution Overview / Implementation Plan)

- **IoT edge (simulation):** Node-RED emulates each taxi's sensors (GPS, battery voltage
  monitor, speedometer, seat-weight sensor) and actuators (motor controller, door lock),
  publishing telemetry to and receiving commands from an MQTT broker.
- **Messaging:** MQTT (publish/subscribe), chosen for low-bandwidth, low-latency,
  high-frequency IoT telemetry over traditional HTTP polling.
- **Event Router (Node.js):** consumes the raw MQTT telemetry stream, validates message
  payloads, and routes valid events onward.
- **Telemetry service (Node.js):** writes filtered/batched telemetry into MongoDB
  (5-second batching window per the Plan, to reduce transaction overhead).
- **Dispatch service (Node.js):** on a ride request, filters available vehicles, selects
  the optimal one (A* heuristic + Haversine distance per the Plan), updates
  PostgreSQL, and sends a dispatch command back through the MQTT broker to the vehicle.
- **Storage:** MongoDB for high-throughput, schema-flexible telemetry (JSON documents:
  timestamp, vehicleID, coordinates, speed, battery level, current state); PostgreSQL for
  transactional/relational data (user accounts, ride histories, billing, static fleet
  info) - chosen for ACID guarantees on ride bookings.
- **Edge-level filtering:** a stationary vehicle whose GPS delta is < 0.0001° between
  readings has its telemetry packet dropped before it reaches the broker.
- **Ordering/consistency:** every telemetry packet gets a Unix timestamp at the
  simulated edge; the database write path drops any packet older than the current
  stored state for that vehicle (last-write-wins by timestamp, not by arrival order).
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
   names a product. Proposed default for Week 4: **Mosquitto**, since it's the
   lightweight industry-standard choice and mirrors what would run in the eventual AWS
   deployment. Needs confirmation before Week 4 starts.
2. **Week 7-8 compute target.** Implementation Plan says containers will be deployed via
   "Amazon Elastic Container Service **or** EC2 Auto Scaling Groups" - an unresolved
   either/or. Doesn't block Weeks 1-6, but needs a decision before Week 7. Proposed
   default: ECS Fargate.
3. **How commuters receive ride status updates.** The Solution Overview's stakeholder
   requirements promise commuters "real-time status updates," but no week's task and
   neither diagram specifies the mechanism. Proposed default: the ride-request endpoint
   (Week 6) returns the assigned vehicle ID and ETA synchronously in its HTTP response.
   A live-push/polling mechanism beyond that is NOT in Weeks 1-6 scope unless confirmed.
4. **Sensor list mismatch.** Solution Overview lists GPS, battery voltage monitor,
   speedometer. Implementation Plan adds a seat-weight sensor. Resolution: Week 2 will
   simulate the union of both (GPS, battery, speedometer, seat-weight).
5. **Public-subnet ingestion wording.** Implementation Plan's cloud section says "an AWS
   API Gateway and an MQTT will be exposed in the public subnet" - unclear phrasing.
   Only affects Week 8 (AWS networking), not Weeks 1-6. Proposed default: API Gateway
   serves the passenger-facing REST API; the MQTT broker has its own TLS-secured public
   endpoint for vehicle connections.

Items 2 and 5 don't block current work (Week 7-8 concerns). Items 1, 3, and 4 affect
Weeks 2-6 and are proceeding under the proposed defaults above unless told otherwise.

## Note on version control

If `git commit` fails with a stuck `.git/index.lock` error, delete the stale lock file
(and any 0-byte temp files in `.git/`) and retry - this can happen after an interrupted
git operation.
