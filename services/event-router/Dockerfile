# syntax=docker/dockerfile:1
#
# Week 7 - build context is the REPO ROOT, not this directory, because this service
# needs schema/telemetry.schema.json, which lives outside services/event-router/.
# Build from the repo root:
#   docker build -f services/event-router/Dockerfile -t dtx-event-router:week7 .

FROM node:22-alpine

WORKDIR /app
ENV NODE_ENV=production

COPY services/event-router/package.json services/event-router/package-lock.json ./
RUN npm ci --omit=dev

COPY services/event-router/src ./src
COPY schema/telemetry.schema.json ./schema/telemetry.schema.json

ENV SCHEMA_PATH=/app/schema/telemetry.schema.json

USER node
CMD ["node", "src/index.js"]
