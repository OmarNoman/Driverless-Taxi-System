#!/bin/bash
# Create the two MongoDB telemetry collections on first container boot.
#
#   telemetry          current state, ONE document per vehicle, upserted, last-write-wins
#                      by edge timestamp. Read by the Dispatch service. $jsonSchema-validated
#                      from schema/telemetry.schema.json (the single source of truth for the
#                      payload shape, also used by services/event-router). Unique on vehicleID.
#
#   telemetry_history  append-only, ONE document per validated packet, for trajectory and
#                      aggregate queries. No validator (written only by our own service from
#                      already-validated packets, and it carries a server-set ingestedAt).
#                      A TTL index on ingestedAt prunes it after HISTORY_TTL_DAYS.
#
# docker-compose.yml mounts schema/telemetry.schema.json at /schema/telemetry.schema.json
# and this script at /docker-entrypoint-initdb.d/.
set -euo pipefail

SCHEMA_PATH="${SCHEMA_PATH:-/schema/telemetry.schema.json}"
HISTORY_TTL_DAYS="${HISTORY_TTL_DAYS:-7}"
SCRIPT="$(mktemp)"

{
  echo "const telemetrySchema = $(cat "$SCHEMA_PATH");"
  echo "const historyTtlSeconds = ${HISTORY_TTL_DAYS} * 24 * 60 * 60;"
  cat <<'EOF'
const target = db.getSiblingDB("driverless_taxi");

// --- telemetry: current state per vehicle ---
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

// --- telemetry_history: append-only, TTL-pruned ---
if (target.getCollectionInfos({ name: "telemetry_history" }).length === 0) {
  target.createCollection("telemetry_history");
}
target.telemetry_history.createIndex({ vehicleID: 1, timestamp: -1 }, { name: "vehicle_time" });
target.telemetry_history.createIndex(
  { ingestedAt: 1 }, { name: "ttl", expireAfterSeconds: historyTtlSeconds }
);

print("driverless_taxi ready - telemetry (validated, current state) + telemetry_history " +
      "(append-only, TTL " + (historyTtlSeconds / 86400) + "d)");
EOF
} > "$SCRIPT"

mongosh --quiet "mongodb://127.0.0.1:27017/driverless_taxi" --file "$SCRIPT"
rm -f "$SCRIPT"
