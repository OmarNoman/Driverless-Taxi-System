# telemetry-service

Consumes the Event Router's validated telemetry stream and persists it into MongoDB in
batches: current state per vehicle, plus an append-only history.

```
validated/+/telemetry ──▶ telemetry-service ──┬─▶ telemetry          (5s, bulk upsert, one doc/vehicle, LWW)
                                               └─▶ telemetry_history  (5s, insertMany, every packet, TTL-pruned)
```

- The MQTT handler only writes to in-memory buffers, so ingestion never blocks on
  database I/O.
- Every `BATCH_MS` both buffers flush. `telemetry` gets one `bulkWrite` of upserts (newest
  packet per vehicle); a `$cond` on `timestamp` in the update pipeline means an
  out-of-order packet can never regress a vehicle's state (plan p6).
- `telemetry_history` gets an `insertMany` of every packet in the window, each stamped with
  a server-set `ingestedAt` that the TTL index prunes on (see `db/mongo/init-telemetry.sh`,
  `HISTORY_TTL_DAYS`).

## Run

Needs the stack from the repo-root `docker compose up -d`, the Node-RED simulation, and
`services/event-router` running.

```bash
cd services/telemetry-service
npm install
npm start
```

| Env var            | Default                     | Purpose                        |
|--------------------|-----------------------------|--------------------------------|
| `MQTT_URL`         | `mqtt://localhost:1883`     | broker address                 |
| `TOPIC_IN`         | `validated/+/telemetry`     | validated stream subscription  |
| `MONGO_URL`        | `mongodb://localhost:27017` | MongoDB address                |
| `MONGO_DB`         | `driverless_taxi`           | database                       |
| `MONGO_COLLECTION` | `telemetry`                 | current-state collection       |
| `MONGO_HISTORY`    | `telemetry_history`         | append-only history collection |
| `BATCH_MS`         | `5000`                      | batching window in ms          |

## Test

```bash
npm test
```

Batcher unit tests: newest-per-vehicle buffering, history keeps every packet, both buffers
cleared on flush, empty-flush no-op, dynamic field set per vehicle type, last-write-wins
upsert shape, failed-flush recovery. No broker or database required.

## Check the data

```bash
docker exec dtx-mongo mongosh driverless_taxi --quiet --eval "db.telemetry.find({}, {vehicleID:1, vehicleType:1, currentState:1, _id:0}).toArray()"
docker exec dtx-mongo mongosh driverless_taxi --quiet --eval "db.telemetry_history.countDocuments()"
```
