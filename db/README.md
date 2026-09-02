# Data layer

Local development databases for the driverless taxi system, per the 1.2D Plan's
Implementation Plan:

- **PostgreSQL** - relational business data (user accounts, ride histories, billing
  statuses, static fleet information), chosen for ACID guarantees on ride bookings.
- **MongoDB** - vehicle telemetry as JSON documents: `telemetry` (current state, one doc
  per vehicle, `$jsonSchema`-validated) and `telemetry_history` (append-only, TTL-pruned).

Both run from the repo-root `docker-compose.yml` (which also runs the MQTT broker).

## Layout

```
db/
├── postgres/
│   ├── schema.sql        relational schema (vehicles, users, rides, payments)
│   ├── seed-fleet.sql    one sedan, one van, one bus (static fleet, with home nodes)
│   └── seed-dev.sql      one demo passenger (dev/test only)
└── mongo/
    ├── init-telemetry.sh     creates telemetry (validated) + telemetry_history (TTL)
    └── sample-telemetry.json one valid document per vehicle type
```

The telemetry payload shape lives in `../schema/telemetry.schema.json` (a `oneOf` of the
three vehicle types, shared with `services/event-router`); `init-telemetry.sh` reads it and
applies it as the MongoDB validator on `telemetry` at first container boot.
`telemetry_history` has no validator (it is written only from already-validated packets)
and a TTL index on `ingestedAt` set from `HISTORY_TTL_DAYS` (default 7).

## Bring it up

```bash
docker compose up -d
```

First boot runs the init scripts automatically. Connection details:

| Service  | URI                                                          |
|----------|--------------------------------------------------------------|
| Postgres | `postgresql://dtx:dtx_dev_pw@localhost:5432/driverless_taxi` |
| MongoDB  | `mongodb://localhost:27017/driverless_taxi`                  |

Credentials are local-dev only.

Stop and keep data: `docker compose down`. Stop and wipe data (init scripts re-run next
start): `docker compose down -v`.

## Check it

Postgres - list the tables and the seeded fleet:

```bash
docker exec dtx-postgres psql -U dtx -d driverless_taxi -c "\dt" -c "TABLE vehicles;"
```

Re-apply the schema to a scratch database to prove it applies cleanly from empty:

```bash
docker exec dtx-postgres psql -U dtx -d postgres -c "CREATE DATABASE schema_check;"
docker exec -i dtx-postgres psql -U dtx -d schema_check -v ON_ERROR_STOP=1 < db/postgres/schema.sql
docker exec dtx-postgres psql -U dtx -d postgres -c "DROP DATABASE schema_check;"
```

MongoDB - confirm the per-type validator is attached and both collections exist:

```bash
docker exec dtx-mongo mongosh driverless_taxi --quiet --eval "db.getCollectionNames()"
docker exec dtx-mongo mongosh driverless_taxi --quiet --eval "db.getCollectionInfos({name:'telemetry'})[0].options.validator['\$jsonSchema'].oneOf.length"
docker exec dtx-mongo mongosh driverless_taxi --quiet --eval "db.telemetry.insertOne({vehicleID:'TAXI-001',vehicleType:'sedan',coordinates:{lat:-37.8136,lon:144.9631},heading:90,speed:34.21,batteryLevel:87.4,currentState:'driving',timestamp:1725000000000,occupancy:{seatsTotal:4,seatsOccupied:1,seatWeightKg:70},doorsLocked:true})"
docker exec dtx-mongo mongosh driverless_taxi --quiet --eval "db.telemetry.insertOne({vehicleID:'TAXI-001',vehicleType:'sedan',currentState:'flying'})"
```

The `oneOf` length is `3`. The first insert succeeds; the second fails with a
`Document failed validation` error.
