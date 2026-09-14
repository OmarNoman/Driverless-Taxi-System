# syntax=docker/dockerfile:1
#
# Week 8 - custom Mongo image with the Week 3 init script baked in, since ECS Fargate
# has no bind-mount volumes. Build context is the REPO ROOT, not this directory,
# because init-telemetry.sh needs schema/telemetry.schema.json, which lives outside
# db/mongo/:
#   docker build -f db/mongo/Dockerfile -t dtx-mongo-seeded:week8 .
#
# Local dev is unchanged - docker-compose.yml still runs plain mongo:7 with
# init-telemetry.sh and the schema file bind-mounted at these same two paths.
# init-telemetry.sh already defaults SCHEMA_PATH to /schema/telemetry.schema.json, so
# it needs zero code changes.

FROM mongo:7

COPY db/mongo/init-telemetry.sh   /docker-entrypoint-initdb.d/01-init-telemetry.sh
COPY schema/telemetry.schema.json /schema/telemetry.schema.json
