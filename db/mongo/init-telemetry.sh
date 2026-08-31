#!/bin/bash
# Week 3/4 - create driverless_taxi.telemetry with schema validation + indexes.
#
# The validator comes from schema/telemetry.schema.json (the single source of truth for
# the telemetry payload shape, also used by services/event-router). docker-compose.yml
# mounts that file at /schema/telemetry.schema.json and this script at
# /docker-entrypoint-initdb.d/, where the mongo entrypoint runs it on first boot.
#
# Design note: telemetry holds the CURRENT state per vehicle (one document each, upserted),
# not an append-only history - matching the Week 5 Telemetry service and the plan's
# last-write-wins rule. Hence the unique index on vehicleID.
set -euo pipefail

SCHEMA_PATH="${SCHEMA_PATH:-/schema/telemetry.schema.json}"
SCRIPT="$(mktemp)"

{
  echo "const telemetrySchema = $(cat "$SCHEMA_PATH");"
  cat <<'EOF'
const target = db.getSiblingDB("driverless_taxi");
const options = {
  validator: { $jsonSchema: telemetrySchema },
  validationLevel: "strict",
  validationAction: "error"
};
if (target.getCollectionInfos({ name: "telemetry" }).length === 0) {
  target.createCollection("telemetry", options);
} else {
  target.runCommand(Object.assign({ collMod: "telemetry" }, options));
}
target.telemetry.createIndex({ vehicleID: 1 }, { name: "vehicle_unique", unique: true });
target.telemetry.createIndex({ timestamp: -1 }, { name: "by_time" });
print("driverless_taxi.telemetry ready - validator from schema/telemetry.schema.json, indexes applied");
EOF
} > "$SCRIPT"

mongosh --quiet "mongodb://127.0.0.1:27017/driverless_taxi" --file "$SCRIPT"
rm -f "$SCRIPT"
