# syntax=docker/dockerfile:1
#
# Week 8 - custom Postgres image with the Week 3 schema + seeds baked in, since ECS
# Fargate has no bind-mount volumes the way docker-compose.yml uses locally. Build
# context is this directory:
#   docker build -t dtx-postgres-seeded:week8 db/postgres
#
# Local dev is unchanged - docker-compose.yml still runs plain postgres:16 with these
# same 3 files bind-mounted. This image is for AWS only. No changes to the SQL files
# themselves: the official image already runs everything under
# /docker-entrypoint-initdb.d in filename order on first boot of an empty data
# directory, identical to what the bind mount already does.

FROM postgres:16

COPY schema.sql     /docker-entrypoint-initdb.d/01-schema.sql
COPY seed-fleet.sql /docker-entrypoint-initdb.d/02-seed-fleet.sql
COPY seed-dev.sql   /docker-entrypoint-initdb.d/03-seed-dev.sql
