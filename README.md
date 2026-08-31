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

Weeks 1-4 done: edge simulation, data layer, and MQTT ingestion. **Week 5 (Telemetry
microservice) is next.** See [`ROADMAP.md`](./ROADMAP.md).

## Project layout (grows week by week - see ROADMAP.md)

```
driverless-taxi-system/
├── ARCHITECTURE.md      finalized design + open decisions
├── ROADMAP.md           Week 1-6 plan, traced to the 1.2D Plan
├── docker-compose.yml   local infra: postgres, mongo, mosquitto (Weeks 3-4)
├── schema/              telemetry.schema.json - shared payload contract
├── node-red/            local Node-RED project (IoT edge simulation) - Weeks 1-2, 4
├── db/                  PostgreSQL schema + MongoDB telemetry validation - Week 3
├── broker/              Mosquitto config - Week 4
└── services/
    └── event-router/    validates the MQTT telemetry stream - Week 4
                         (telemetry-service, dispatch-service come in Weeks 5-6)
```

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

Start the Event Router:

```
cd services/event-router
npm install
npm start
```

See [`db/README.md`](./db/README.md) and
[`services/event-router/README.md`](./services/event-router/README.md) for details and
checks.

## Version control

If `git commit` ever fails with a stuck `.git/index.lock` error, delete that file (and
any 0-byte temp files in `.git/`) and retry - this happens after an interrupted git
operation.
