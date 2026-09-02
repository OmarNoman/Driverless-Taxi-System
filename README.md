# Driver-less Taxi System for a Smart City

SIT314 (Software Architecture and Scalability for IoT) Distinction project - a scalable,
event-driven IoT platform for managing a fleet of simulated driverless taxis.

This repository is the implementation of the **1.2D Project Plan**, which is the single
source of truth for scope, requirements, and the week-by-week build order. See:

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) - finalized system design, confirmed decisions,
  and open decisions still needing a call.
- [`ROADMAP.md`](./ROADMAP.md) - the Week 1-6 implementation plan, mapped directly to the
  1.2D Plan, with dependencies and validation criteria for each week.

## Status

Weeks 1-6 done: the full request-to-dispatch loop runs locally - edge simulation, data
layer, MQTT ingestion, the batching Telemetry service, and the Dispatch service. A
post-review revision added per-vehicle-type telemetry, an append-only telemetry history,
and A* routing over a real Melbourne road graph (see `ARCHITECTURE.md`). Weeks 7-9
(containerisation, AWS deployment + auto-scaling, load testing) are out of scope for this
implementation pass. See [`ROADMAP.md`](./ROADMAP.md).

## Project layout

```
driverless-taxi-system/
├── ARCHITECTURE.md      finalized design + open decisions + post-review revisions
├── ROADMAP.md           Week 1-6 plan, traced to the 1.2D Plan
├── docker-compose.yml   local infra: postgres, mongo, mosquitto
├── schema/              telemetry.schema.json - shared per-vehicle-type payload contract
├── graph/               melbourne.json - road network for A* dispatch + route following
├── node-red/            local Node-RED project (IoT edge simulation)
├── db/                  PostgreSQL schema + MongoDB init (telemetry + telemetry_history)
├── broker/              Mosquitto config
└── services/
    ├── event-router/       validates the MQTT telemetry stream
    ├── telemetry-service/   batches the validated stream into MongoDB
    └── dispatch-service/    ride requests -> A* nearest vehicle -> MQTT command
```

The simulated fleet is one sedan (TAXI-001), one van (TAXI-002) and one bus (TAXI-003).
Sedans and vans are dispatchable and drive graph routes; the bus runs a fixed loop.

## Running it locally

Start the databases and MQTT broker:

```
docker compose up -d
```

Start the Node-RED simulation:

```
cd node-red
npm install
npm start
```

The Node-RED admin UI is at http://127.0.0.1:1880/. Flows live in
`node-red/flows.json` (not the global `~/.node-red`), so the simulation is
version-controlled with the rest of the code.

Start the services, each in its own terminal:

```
cd services/event-router && npm install && npm start
```

```
cd services/telemetry-service && npm install && npm start
```

```
cd services/dispatch-service && npm install && npm start
```

Then request a ride. Pickup and dropoff are named road-graph nodes (`GET /nodes` lists
them); the demo passenger has id 1:

```
curl -s -XPOST localhost:8080/rides -H 'content-type: application/json' \
  -d '{"userId":1,"pickup":"Camberwell","dropoff":"St Kilda","passengers":2}'
```

The response carries the assigned vehicle, ETA and the suburb route; the vehicle then
drives that route on the Node-RED map.

Each component has its own README with details and checks:
[`db/`](./db/README.md), [`event-router/`](./services/event-router/README.md),
[`telemetry-service/`](./services/telemetry-service/README.md),
[`dispatch-service/`](./services/dispatch-service/README.md).

## Version control

If `git commit` ever fails with a stuck `.git/index.lock` error, delete that file (and
any 0-byte temp files in `.git/`) and retry - this happens after an interrupted git
operation.
