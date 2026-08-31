// Week 6 - Dispatch microservice
//
// Plan (Project Plan, Week 6): "Implement the routing algorithm to calculate the nearest
// available vehicle and send dispatch commands back to the Node-RED actuators via the MQTT
// broker."
//
// POST /rides { userId, pickup:{lat,lon}, dropoff:{lat,lon} }
//   -> filter available vehicles (Postgres status + live Mongo position)
//   -> pick the best one (select.js: A* cost model f = g + h, Haversine distances)
//   -> write the trip to Postgres, mark the vehicle on_trip (one transaction)
//   -> publish a dispatch command on fleet/<vehicleId>/command
//   -> return the assignment synchronously (ARCHITECTURE.md open decision #3)

import http from "node:http";
import mqtt from "mqtt";
import { createStore } from "./store.js";
import { selectVehicle, haversineKm } from "./select.js";

const HTTP_PORT = Number(process.env.HTTP_PORT || 8080);
const MQTT_URL = process.env.MQTT_URL || "mqtt://localhost:1883";
const PG_URL =
  process.env.PG_URL || "postgresql://dtx:dtx_dev_pw@localhost:5432/driverless_taxi";
const MONGO_URL = process.env.MONGO_URL || "mongodb://localhost:27017";
const MONGO_DB = process.env.MONGO_DB || "driverless_taxi";
const AVG_SPEED_KMH = Number(process.env.AVG_SPEED_KMH || 30);

const store = createStore({ pgUrl: PG_URL, mongoUrl: MONGO_URL, mongoDb: MONGO_DB });
await store.connect();
console.log("[dispatch] connected to postgres + mongo");

const mqttClient = mqtt.connect(MQTT_URL, { reconnectPeriod: 2000 });
mqttClient.on("connect", () => console.log(`[dispatch] connected to ${MQTT_URL}`));
mqttClient.on("error", (e) => console.error("[dispatch] mqtt error:", e.message));

const round1 = (n) => Math.round(n * 10) / 10;

function send(res, status, obj) {
  const s = JSON.stringify(obj);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(s),
  });
  res.end(s);
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (c) => {
      body += c;
      if (body.length > 1e6) reject(new Error("request body too large"));
    });
    req.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch {
        reject(new Error("invalid JSON body"));
      }
    });
    req.on("error", reject);
  });
}

const isCoord = (c) =>
  c &&
  typeof c.lat === "number" &&
  typeof c.lon === "number" &&
  c.lat >= -90 &&
  c.lat <= 90 &&
  c.lon >= -180 &&
  c.lon <= 180;

async function handleRide(req, res) {
  let body;
  try {
    body = await readJson(req);
  } catch (e) {
    return send(res, 400, { error: e.message });
  }

  const { userId, pickup, dropoff } = body;
  if (!Number.isInteger(userId) || !isCoord(pickup) || !isCoord(dropoff)) {
    return send(res, 400, {
      error: "expected { userId: int, pickup: {lat, lon}, dropoff: {lat, lon} }",
    });
  }
  if (!(await store.userExists(userId))) {
    return send(res, 404, { error: `user ${userId} not found` });
  }

  const candidates = await store.availableCandidates();
  if (candidates.length === 0) {
    return send(res, 409, { error: "no available vehicle with a known position" });
  }

  const choice = selectVehicle(candidates, pickup);
  const tripDistanceKm = haversineKm(pickup, dropoff);

  const trip = await store.assignTrip({
    userId,
    vehicleId: choice.vehicleId,
    pickup,
    dropoff,
    tripDistanceKm,
  });
  if (!trip) {
    return send(res, 409, { error: "selected vehicle was just taken, please retry" });
  }

  const etaMinutes = round1((choice.h / AVG_SPEED_KMH) * 60);

  mqttClient.publish(
    `fleet/${choice.vehicleId}/command`,
    JSON.stringify({
      vehicleID: choice.vehicleId,
      command: "dispatch",
      rideId: trip.rideId,
      pickup,
    }),
    { qos: 0 }
  );

  console.log(
    `[dispatch] ride ${trip.rideId} -> ${choice.vehicleId} ` +
      `(pickup ${choice.h.toFixed(2)}km, f=${choice.f.toFixed(2)}, eta ${etaMinutes}min, ` +
      `candidates=${candidates.length})`
  );

  send(res, 200, {
    rideId: trip.rideId,
    vehicleId: choice.vehicleId,
    etaMinutes,
    pickupDistanceKm: round1(choice.h),
    tripDistanceKm: round1(tripDistanceKm),
    assignedAt: trip.assignedAt,
  });
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") return send(res, 200, { ok: true });
  if (req.method === "POST" && req.url === "/rides") {
    return handleRide(req, res).catch((e) => {
      console.error("[dispatch] error:", e);
      send(res, 500, { error: "internal error" });
    });
  }
  send(res, 404, { error: "not found" });
});

server.listen(HTTP_PORT, () =>
  console.log(`[dispatch] listening on :${HTTP_PORT}  (POST /rides)`)
);

let shuttingDown = false;
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`\n[dispatch] ${sig} - shutting down`);
    server.close();
    mqttClient.end(true);
    try {
      await store.close();
    } finally {
      process.exit(0);
    }
  });
}
