#!/bin/bash
# 6.4HD - PostgreSQL streaming-replication standby entrypoint.
#
# Replaces the official image's docker-entrypoint.sh entirely (Dockerfile.replica sets
# this as ENTRYPOINT, not CMD) - that entrypoint auto-runs initdb whenever it finds
# PGDATA empty, which is exactly this replica's starting state on every Fargate task
# launch (no persistent storage - see the open-risks note in the 6.4HD report). This
# script runs pg_basebackup to populate PGDATA from the primary instead, before postgres
# itself ever starts, then execs postgres directly.
#
# Runs as root (the base image's default at container start, before its own entrypoint
# would normally drop to the postgres user via gosu) - gosu is used explicitly here for
# the same reason the official entrypoint uses it: postgres refuses to run as root.
set -euo pipefail

PRIMARY_HOST="${PRIMARY_HOST:?PRIMARY_HOST must be set}"
REPL_PASSWORD="${REPL_PASSWORD:?REPL_PASSWORD must be set}"
PGDATA="${PGDATA:-/var/lib/postgresql/data}"

if [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ]; then
  echo "replica-entrypoint: PGDATA is empty - running pg_basebackup from $PRIMARY_HOST"

  RETRIES=10
  until gosu postgres pg_basebackup \
    -D "$PGDATA" \
    -R \
    -Fp \
    -Xs \
    -d "postgresql://repl_user:${REPL_PASSWORD}@${PRIMARY_HOST}:5432/postgres"
  do
    RETRIES=$((RETRIES - 1))
    if [ "$RETRIES" -le 0 ]; then
      echo "replica-entrypoint: pg_basebackup failed after all retries - giving up" >&2
      exit 1
    fi
    echo "replica-entrypoint: pg_basebackup failed, $RETRIES retries left, retrying in 5s"
    rm -rf "${PGDATA:?}"/*
    sleep 5
  done

  chown -R postgres:postgres "$PGDATA"
  chmod 0700 "$PGDATA"
else
  echo "replica-entrypoint: PGDATA already has data, skipping pg_basebackup"
fi

exec gosu postgres postgres
