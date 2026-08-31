# dispatch-service (Week 6)

Ride-request entry point. Picks the best available vehicle, records the trip in
PostgreSQL, and dispatches the vehicle over MQTT.

```
POST /rides ──▶ dispatch-service ──┬─▶ PostgreSQL  rides (+ vehicles.status = on_trip)
                                    ├─▶ MQTT  fleet/<vehicleId>/command  { command: "dispatch" }
                                    └─▶ 200  { rideId, vehicleId, etaMinutes, ... }
```

- **Available vehicles**: `vehicles.status = 'available'` in Postgres, joined with their
  latest position from MongoDB `telemetry` (written by the Telemetry service).
- **Selection** ([select.js](src/select.js)): A* cost model `f(v) = g(v) + h(v)` where
  `h` is the Haversine distance to the pickup and `g` adds km-equivalent penalties for
  low battery and for being in motion. Minimum `f` wins.
- **Trip record + `on_trip` flip** happen in one transaction; a guarded `UPDATE` means a
  vehicle can't be dispatched twice concurrently.
- **Response** is synchronous - the assigned vehicle and ETA come straight back in the
  HTTP response (ARCHITECTURE.md open decision #3). No live status push is built.

## Run

Needs the repo-root `docker compose up -d`, plus the Node-RED simulation, `event-router`
and `telemetry-service` running so MongoDB has live positions.

```bash
cd services/dispatch-service
npm install
npm start
```

| Env var         | Default                                                        |
|-----------------|---------------------------------------------------------------|
| `HTTP_PORT`     | `8080`                                                       |
| `MQTT_URL`      | `mqtt://localhost:1883`                                      |
| `PG_URL`        | `postgresql://dtx:dtx_dev_pw@localhost:5432/driverless_taxi` |
| `MONGO_URL`     | `mongodb://localhost:27017`                                 |
| `MONGO_DB`      | `driverless_taxi`                                           |
| `AVG_SPEED_KMH` | `30` (used only for the ETA estimate)                       |

## Request a ride

`userId` must exist. `db/postgres/seed-dev.sql` creates one demo passenger with id `1`.

```bash
curl -s -XPOST localhost:8080/rides \
  -H 'content-type: application/json' \
  -d '{"userId":1,"pickup":{"lat":-37.8140,"lon":144.9630},"dropoff":{"lat":-37.8000,"lon":144.9700}}'
```

Responses: `200` assignment, `400` bad body, `404` unknown user, `409` no vehicle
available.

## Test

```bash
npm test
```

Unit tests for the selection logic (Haversine, nearest wins, battery penalty flips the
choice, `f = g + h`, empty candidate list). No database or broker required.
