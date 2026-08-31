# event-router (Week 4)

Consumes the raw MQTT vehicle telemetry stream, validates each payload against the shared
schema, and re-publishes the valid ones on a clean topic for the Week 5 Telemetry service.
It does not touch a database.

```
fleet/+/telemetry ──▶ event-router ──▶ validated/<vehicleID>/telemetry
                          │
                          └─ malformed messages are logged and dropped
```

## Run

Needs the MQTT broker from the repo-root `docker compose up -d` and the Node-RED
simulation publishing telemetry.

```bash
cd services/event-router
npm install
npm start
```

| Env var            | Default                  | Purpose                          |
|--------------------|--------------------------|----------------------------------|
| `MQTT_URL`         | `mqtt://localhost:1883`  | broker address                   |
| `TOPIC_IN`         | `fleet/+/telemetry`      | telemetry subscription           |
| `TOPIC_OUT_PREFIX` | `validated`              | prefix for the re-published feed |
| `SCHEMA_PATH`      | `../../../schema/telemetry.schema.json` | validation schema  |

## Test

```bash
npm test
```

Unit tests for the validator (accepts well-formed packets, rejects bad JSON, unknown
`currentState`, missing fields, out-of-range values, unknown properties, and topic vs
payload `vehicleID` mismatch). No broker required.
