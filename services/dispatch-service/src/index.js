// Dispatch microservice
//
// Plan (Project Plan, Week 6): "Implement the routing algorithm to calculate the nearest
// available vehicle and send dispatch commands back to the Node-RED actuators via the MQTT
// broker."
//
// POST /rides { userId, pickup: "<landmark name>", dropoff: "<landmark name>", passengers }
//   -> filter available vehicles that can seat the party (Postgres) + live position (Mongo)
//   -> A* over graph/melbourne.json from each vehicle's nearest node to the pickup node
//   -> pick the lowest-cost vehicle (select.js: A* road km + battery + right-size penalties)
//   -> write the trip to Postgres, mark the vehicle on_trip (one transaction)
//   -> publish a dispatch command carrying the node-id route on fleet/<vehicleId>/command
//   -> return the assignment, ETA and the suburb route synchronously
//
// GET /nodes    -> the landmark names a request can use
// GET /health

import http from "node:http";
import mqtt from "mqtt";
import { createStore } from "./store.js";
import { loadGraph } from "./graph.js";
import { selectVehicle } from "./select.js";

const HTTP_PORT = Number(process.env.HTTP_PORT || 8080);
const MQTT_URL = process.env.MQTT_URL || "mqtt://localhost:1883";
const PG_URL =
  process.env.PG_URL || "postgresql://dtx:dtx_dev_pw@localhost:5432/driverless_taxi";
const MONGO_URL = process.env.MONGO_URL || "mongodb://localhost:27017";
const MONGO_DB = process.env.MONGO_DB || "driverless_taxi";
const AVG_SPEED_KMH = Number(process.env.AVG_SPEED_KMH || 30);

const graph = loadGraph();
const store = createStore({ pgUrl: PG_URL, mongoUrl: MONGO_URL, mongoDb: MONGO_DB });
await store.connect();
console.log(`[dispatch] graph ${graph.names().length} nodes; connected to postgres + mongo`);

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

async function handleRide(req, res) {
  let body;
  try {
    body = await readJson(req);
  } catch (e) {
    return send(res, 400, { error: e.message });
  }

  const { userId, pickup, dropoff } = body;
  const passengers = body.passengers ?? 1;

  if (
    !Number.isInteger(userId) ||
    typeof pickup !== "string" ||
    typeof dropoff !== "string" ||
    !Number.isInteger(passengers) ||
    passengers < 1
  ) {
    return send(res, 400, {
      error:
        'expected { userId: int, pickup: "<landmark>", dropoff: "<landmark>", passengers?: int >= 1 }',
    });
  }

  const pickupNode = graph.idByName(pickup);
  const dropoffNode = graph.idByName(dropoff);
  if (pickupNode === null || dropoffNode === null) {
    return send(res, 400, {
      error: "unknown landmark",
      unknown: [pickupNode === null ? pickup : null, dropoffNode === null ? dropoff : null].filter(Boolean),
      validLandmarks: graph.names(),
    });
  }

  if (!(await store.userExists(userId))) {
    return send(res, 404, { error: `user ${userId} not found` });
  }

  const candidates = await store.availableCandidates(passengers);
  if (candidates.length === 0) {
    return send(res, 409, { error: `no available vehicle seats ${passengers} with a known position` });
  }

  const choice = selectVehicle(candidates, pickupNode, graph, passengers);
  if (!choice) {
    return send(res, 409, { error: "no vehicle can reach the pickup" });
  }

  const trip = graph.aStar(pickupNode, dropoffNode); // { path, costKm }
  const pickupCoord = graph.node.get(pickupNode);
  const dropoffCoord = graph.node.get(dropoffNode);

  const assigned = await store.assignTrip({
    userId,
    vehicleId: choice.vehicleId,
    pickup: { lat: pickupCoord.lat, lon: pickupCoord.lon },
    dropoff: { lat: dropoffCoord.lat, lon: dropoffCoord.lon },
    tripDistanceKm: trip.costKm,
  });
  if (!assigned) {
    return send(res, 409, { error: "selected vehicle was just taken, please retry" });
  }

  const etaMinutes = round1((choice.roadKm / AVG_SPEED_KMH) * 60);

  mqttClient.publish(
    `fleet/${choice.vehicleId}/command`,
    JSON.stringify({
      vehicleID: choice.vehicleId,
      command: "dispatch",
      rideId: assigned.rideId,
      pickup: graph.name(pickupNode),
      passengers,
      route: choice.route,
    }),
    { qos: 0 }
  );

  console.log(
    `[dispatch] ride ${assigned.rideId} -> ${choice.vehicleId} (${choice.vehicleType}) ` +
      `pickup ${graph.name(choice.startNode)}->${graph.name(pickupNode)} ` +
      `${choice.roadKm.toFixed(1)}km score=${choice.score.toFixed(1)} eta=${etaMinutes}min`
  );

  send(res, 200, {
    rideId: assigned.rideId,
    vehicleId: choice.vehicleId,
    vehicleType: choice.vehicleType,
    etaMinutes,
    pickupDistanceKm: round1(choice.roadKm),
    tripDistanceKm: round1(trip.costKm),
    route: choice.route.map((id) => graph.name(id)),
    tripRoute: trip.path.map((id) => graph.name(id)),
    assignedAt: assigned.assignedAt,
  });
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/health") return send(res, 200, { ok: true });
  if (req.method === "GET" && req.url === "/nodes") {
    return send(res, 200, {
      nodes: [...graph.node.values()].map((n) => ({ id: n.id, name: n.name })),
    });
  }
  if (req.method === "POST" && req.url === "/rides") {
    return handleRide(req, res).catch((e) => {
      console.error("[dispatch] error:", e);
      send(res, 500, { error: "internal error" });
    });
  }
  send(res, 404, { error: "not found" });
});

server.listen(HTTP_PORT, () =>
  console.log(`[dispatch] listening on :${HTTP_PORT}  (POST /rides, GET /nodes)`)
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
