# syntax=docker/dockerfile:1
#
# Week 7 - build context is the REPO ROOT, not this directory, because this service
# needs graph/melbourne.json, which lives outside services/dispatch-service/.
# Build from the repo root:
#   docker build -f services/dispatch-service/Dockerfile -t dtx-dispatch-service:week7 .

FROM node:22-alpine

WORKDIR /app
ENV NODE_ENV=production

COPY services/dispatch-service/package.json services/dispatch-service/package-lock.json ./
RUN npm ci --omit=dev

COPY services/dispatch-service/src ./src
COPY graph/melbourne.json ./graph/melbourne.json

ENV GRAPH_PATH=/app/graph/melbourne.json

EXPOSE 8080
USER node
CMD ["node", "src/index.js"]
