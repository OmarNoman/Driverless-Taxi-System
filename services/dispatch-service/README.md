# dispatch-service

Ride-request entry point. Picks the best available vehicle by A* road distance over the
Melbourne graph, records the trip in PostgreSQL, and dispatches the vehicle over MQTT.

```
POST /rides ──▶ dispatch-service ──┬─▶ PostgreSQL  rides (+ vehicles.status = on_trip)
                                    ├─▶ MQTT  fleet/<vehicleId>/command  { command, route }
                                    └─▶ 200  { rideId, vehicleId, etaMinutes, route, ... }
```

- **Graph** ([graph.js](src/graph.js)): loads `graph/melbourne.json` (21 suburb nodes, 36
  undirected edges). `aStar(start, goal)` uses Haversine km as the edge cost and Haversine
  to the goal node as the heuristic. `nearestNode()` snaps a live position to a node.
- **Candidates**: `vehicles.status = 'available'` AND `passenger_seats >= passengers` in
  Postgres, joined with each vehicle's latest position from MongoDB `telemetry`. The bus
  is not `available`, so it is never a candidate.
- **Selection** ([select.js](src/select.js)): for each candidate, A* from its nearest node
  to the pickup node; score = `roadKm + batteryPenaltyKm + sizePenaltyKm`. Lowest wins.
- **Trip record + `on_trip` flip** happen in one transaction; a guarded `UPDATE` means a
  vehicle can't be dispatched twice concurrently.
- **Cache-aside on `availableCandidates`** ([store.js](src/store.js), 6.4HD): a Redis
  `GET avail:<minSeats>` short-circuits both the Postgres and Mongo round trips on a hit;
  a miss runs the query as before and `SETEX`s the result for 3s. `assignTrip` deletes the
  small fixed set of `avail:1..7` keys after a successful commit. The guarded `UPDATE`
  above already makes a stale read safe (worst case is the existing 409 retry path), so the
  TTL only bounds how often that retry fires, not correctness.
- **Postgres read replica** ([store.js](src/store.js), 6.4HD): `availableCandidates`'s
  Postgres query runs against `readPool`, a second connection pool built from the optional
  `PG_READ_URL` env var (AWS only - unset locally, so `readPool` is just `pool` there,
  zero behavior change). `assignTrip`'s `UPDATE`/`INSERT` always stay on the primary
  `pool`, untouched.
- **Response** is synchronous (a deliberate design decision, no live push or polling): the assigned vehicle,
  ETA, and the suburb route come straight back. The dispatch command carries the node-id
  route for the simulator to drive.

## Run

Needs the repo-root `docker compose up -d`, plus the Node-RED simulation, `event-router`
and `telemetry-service` running so MongoDB has live positions.

```bash
cd services/dispatch-service
npm install
npm start
```

| Env var         | Default                                                     |
|-----------------|------------------------------------------------------------|
| `HTTP_PORT`     | `8080` (clashes with Jenkins on this machine, use `8090`) |
| `MQTT_URL`      | `mqtt://localhost:1883`                                    |
| `PG_URL`        | `postgresql://dtx:dtx_dev_pw@localhost:5432/driverless_taxi` |
| `PG_READ_URL`   | unset (falls back to `PG_URL` - no read replica locally)   |
| `MONGO_URL`     | `mongodb://localhost:27017`                                |
| `MONGO_DB`      | `driverless_taxi`                                          |
| `REDIS_URL`     | `redis://localhost:6379`                                   |
| `AVG_SPEED_KMH` | `30` (ETA estimate only)                                   |
| `GRAPH_PATH`    | `../../../graph/melbourne.json`                            |

## Endpoints

- `GET /health` -> `{ ok: true }`
- `GET /nodes` -> the landmark names a request can use for `pickup` / `dropoff`
- `POST /rides` -> assign a vehicle

`userId` must exist (`db/postgres/seed-dev.sql` seeds a demo passenger with id `1`).
`pickup` and `dropoff` are landmark names (case-insensitive). `passengers` defaults to 1.

```bash
curl -s -XPOST localhost:8090/rides -H 'content-type: application/json' \
  -d '{"userId":1,"pickup":"Camberwell","dropoff":"St Kilda","passengers":2}'
```

Responses: `200` assignment, `400` bad body or unknown landmark, `404` unknown user,
`409` no vehicle can seat the party.

## Test

```bash
npm test
```

`graph.test.js` (A* shortest paths, admissible heuristic, symmetry, `nearestNode`) and
`select.test.js` (nearest by road distance, battery and charging penalties, right-size
preference, score decomposition). No database or broker required.
