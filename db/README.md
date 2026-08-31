# Data layer (Week 3)

Local development databases for the driverless taxi system, per the 1.2D Plan's
Implementation Plan:

- **PostgreSQL** - relational business data (user accounts, ride histories, billing
  statuses, static fleet information), chosen for ACID guarantees on ride bookings.
- **MongoDB** - high-throughput vehicle telemetry as JSON documents, with server-side
  schema validation.

Docker is only a convenient local runtime for the two databases here. Containerising the
Node.js services is a Week 7 task, not this one.

## Layout

```
db/
├── docker-compose.yml         postgres:16 + mongo:7, run the init scripts on first boot
├── postgres/
│   ├── schema.sql             relational schema (vehicles, users, rides, payments)
│   └── seed-fleet.sql         3 static vehicle rows matching the simulator
└── mongo/
    ├── init-telemetry.js      creates driverless_taxi.telemetry with $jsonSchema + indexes
    ├── telemetry.schema.json  standalone copy of that schema (for the Week 4 Event Router)
    └── sample-telemetry.json  one valid telemetry document
```

## Bring it up

```bash
docker compose -f db/docker-compose.yml up -d
```

First boot runs the init scripts automatically. Connection details:

| Service  | URI                                                        |
|----------|------------------------------------------------------------|
| Postgres | `postgresql://dtx:dtx_dev_pw@localhost:5432/driverless_taxi` |
| MongoDB  | `mongodb://localhost:27017/driverless_taxi`                 |

Credentials are local-dev only.

Stop and keep data:

```bash
docker compose -f db/docker-compose.yml down
```

Stop and wipe data (init scripts re-run next start):

```bash
docker compose -f db/docker-compose.yml down -v
```

## Check it

Postgres - list the tables and the seeded fleet:

```bash
docker exec dtx-postgres psql -U dtx -d driverless_taxi -c "\dt" -c "TABLE vehicles;"
```

Re-apply the schema to a scratch database to prove it applies cleanly from empty:

```bash
docker exec dtx-postgres psql -U dtx -d postgres -c "CREATE DATABASE schema_check;"
docker exec -i dtx-postgres psql -U dtx -d schema_check < db/postgres/schema.sql
docker exec dtx-postgres psql -U dtx -d postgres -c "DROP DATABASE schema_check;"
```

MongoDB - confirm the validator is attached, then check it accepts a valid document and
rejects a malformed one:

```bash
docker exec dtx-mongo mongosh driverless_taxi --quiet --eval "db.getCollectionInfos({name:'telemetry'})[0].options.validator"
docker exec dtx-mongo mongosh driverless_taxi --quiet --eval "db.telemetry.insertOne({vehicleID:'TAXI-001',coordinates:{lat:-37.8136,lon:144.9631},speed:34.21,batteryLevel:87.4,currentState:'driving',seatWeightKg:72.5,timestamp:1725000000000})"
docker exec dtx-mongo mongosh driverless_taxi --quiet --eval "db.telemetry.insertOne({vehicleID:'TAXI-001',currentState:'flying'})"
```

The first insert succeeds; the second fails with a `Document failed validation` error.
