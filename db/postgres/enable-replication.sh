#!/bin/bash
# 6.4HD - enable streaming replication on the Postgres primary: sets the WAL/replication
# GUCs, creates the replication role, and opens pg_hba.conf to it from within the VPC.
#
# wal_level/max_wal_senders/max_replication_slots are postmaster-context settings -
# ALTER SYSTEM only writes them to postgresql.auto.conf, it doesn't apply them to the
# server this script is running against. That's fine here: like every initdb.d script,
# this runs against a TEMPORARY bootstrap instance that the official image tears down
# and replaces with a fresh `postgres` process (the real, long-running one) right after -
# a genuine process restart, which is exactly what these settings need to take effect.
#
# pg_hba.conf edits can't go through SQL, hence a shell script rather than another .sql
# file. Named to sort before 01-schema.sql, though order doesn't actually matter for what
# this script does (no dependency between the two).
set -euo pipefail

REPL_PASSWORD="${REPL_PASSWORD:?REPL_PASSWORD must be set}"
REPL_CIDR="${REPL_CIDR:-10.20.0.0/16}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  ALTER SYSTEM SET wal_level = 'replica';
  ALTER SYSTEM SET max_wal_senders = 5;
  ALTER SYSTEM SET max_replication_slots = 5;
  CREATE ROLE repl_user WITH REPLICATION LOGIN PASSWORD '${REPL_PASSWORD}';
EOSQL

echo "host replication repl_user ${REPL_CIDR} md5" >> "$PGDATA/pg_hba.conf"

echo "enable-replication: wal_level/max_wal_senders/max_replication_slots set, repl_user created, pg_hba.conf updated"
