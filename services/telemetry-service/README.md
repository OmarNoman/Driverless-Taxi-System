# telemetry-service (Week 5)

Consumes the Event Router's validated telemetry stream and persists current vehicle state
into MongoDB in batches.

```
validated/+/telemetry ──▶ telemetry-service ──▶ MongoDB  driverless_taxi.telemetry
                              (5s window, bulk upsert, one doc per vehicle)
```

- The MQTT handler only writes to an in-memory `Map` (newest packet per vehicle), so
  ingestion never blocks on database I/O.
- Every `BATCH_MS` the buffer is flushed with a single `bulkWrite` of upserts.
- Last-write-wins: the update pipeline only lets a field move forward when the incoming
  edge `timestamp` is newer than the stored one, so out-of-order packets cannot regress
  a vehicle's state (plan p6).

## Run

Needs the stack from the repo-root `docker compose up -d`, the Node-RED simulation, and
`services/event-router` running.

```bash
cd services/telemetry-service
npm install
npm start
```

| Env var            | Default                       | Purpose                        |
|--------------------|-------------------------------|--------------------------------|
| `MQTT_URL`         | `mqtt://localhost:1883`       | broker address                 |
| `TOPIC_IN`         | `validated/+/telemetry`       | validated stream subscription  |
| `MONGO_URL`        | `mongodb://localhost:27017`   | MongoDB address                |
| `MONGO_DB`         | `driverless_taxi`             | database                       |
| `MONGO_COLLECTION` | `telemetry`                   | collection                     |
| `BATCH_MS`         | `5000`                        | batching window in ms          |

## Test

```bash
npm test
```

Unit tests for the batcher (newest-per-vehicle buffering, one bulk op per vehicle,
empty-flush no-op, last-write-wins upsert shape, failed-flush recovery). No broker or
database required.

## Check the data

```bash
docker exec dtx-mongo mongosh driverless_taxi --quiet --eval "db.telemetry.find({}, {vehicleID:1, currentState:1, timestamp:1, _id:0}).toArray()"
```
