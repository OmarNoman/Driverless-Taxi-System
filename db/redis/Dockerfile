# syntax=docker/dockerfile:1
#
# 6.4HD - stock Redis, re-pushed through ECR purely because this VPC has no NAT Gateway
# (a private-subnet Fargate task can't pull straight from Docker Hub, unlike Mosquitto's
# public-subnet task in ecs.tf). No COPY: this is a pure cache, no seed data to bake in.
#   docker build -t dtx-redis:week9 db/redis

FROM redis:7-alpine
