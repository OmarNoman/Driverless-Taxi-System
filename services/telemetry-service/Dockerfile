# syntax=docker/dockerfile:1
#
# Week 7 - this service needs no file outside its own directory, so the build context
# is just this directory:
#   docker build -t dtx-telemetry-service:week7 services/telemetry-service

FROM node:22-alpine

WORKDIR /app
ENV NODE_ENV=production

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src

USER node
CMD ["node", "src/index.js"]
