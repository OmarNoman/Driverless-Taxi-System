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
#
# 6.4HD: on the AWS replica-set primary (terraform/ecs.tf), the official mongo image's
# entrypoint runs this script against a TEMPORARY bootstrap instance that still inherits
# --replSet dtxrs - and a --replSet-configured node can never accept writes until
# rs.initiate() has run against it, which can't happen until this container survives
# startup. Fargate has no persistent storage, so every primary restart hits this from
# empty. SKIP_INIT=true (set only on that primary's task definition) defers this script
# entirely; terraform/README.md's manual rs.initiate() step re-runs it afterwards as a
# one-off task, with MONGO_HOST pointed at the now-real primary over the NLB instead of
# the local bootstrap instance. Local dev (docker-compose.yml) sets neither var, so this
# script's behavior there is unchanged.
set -euo pipefail

# Guard block, not an early `exit`: the official image's entrypoint sources this script
# rather than running it as a subprocess, so `exit 0` here would terminate the entrypoint
# itself (and the whole container) before it ever reaches the final `exec mongod` -
# confirmed by hitting this directly. Falling off the end of an `if` block is safe in
# both invocation contexts (sourced by the entrypoint, or run directly as a one-off task
# per terraform/README.md's post-rs.initiate() step).
if [ "${SKIP_INIT:-}" = "true" ]; then
  echo "SKIP_INIT=true - deferring telemetry schema setup until after rs.initiate() (6.4HD replica set)"
else
  MONGO_HOST="${MONGO_HOST:-127.0.0.1}"
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

  mongosh --quiet "mongodb://${MONGO_HOST}:27017/driverless_taxi" --file "$SCRIPT"
  rm -f "$SCRIPT"
fi
