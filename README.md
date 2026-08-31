# Driver-less Taxi System for a Smart City

SIT314 (Software Architecture and Scalability for IoT) Distinction project — a scalable,
event-driven IoT platform for managing a fleet of simulated driverless taxis.

This repository is the implementation of the **1.2D Project Plan**, which is the single
source of truth for scope, requirements, and the week-by-week build order. See:

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — finalized system design, confirmed decisions,
  and open decisions still needing a call.
- [`ROADMAP.md`](./ROADMAP.md) — the Week 1–6 implementation plan, mapped directly to the
  1.2D Plan, with dependencies and validation criteria for each week.

## Status

Currently: **Week 1 — Architecture & Edge Setup** (repo + Node-RED environment).

## Project layout (grows week by week — see ROADMAP.md)

```
driverless-taxi-system/
├── ARCHITECTURE.md      finalized design + open decisions (Week 1)
├── ROADMAP.md           Week 1-6 plan, traced to the 1.2D Plan
├── node-red/            local Node-RED project (IoT edge simulation) — Week 1-2
├── db/                  PostgreSQL schema + MongoDB structure       — Week 3 (not yet created)
├── services/            Node.js microservices (event-router,        — Week 4-6 (not yet created)
│                        telemetry-service, dispatch-service)
```

## Running Node-RED locally

```
cd node-red
npm install
npm start
```

Node-RED admin UI will be available at http://127.0.0.1:1880/ once started. Flows are
stored in this project (`node-red/flows.json`), not in the global `~/.node-red` directory,
so the simulation is version-controlled alongside the rest of the code.

## Version control

Run `git init`, `git add -A`, and `git commit` from a local terminal to set this up.
If `git commit` ever fails with a stuck `.git/index.lock` error, delete that file (and
any 0-byte temp files in `.git/`) and retry - this happens after an interrupted git
operation.
