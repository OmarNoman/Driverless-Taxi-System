// Week 5 - Telemetry microservice
//
// Plan (Project Plan, Week 5): "Develop the Node.js Telemetry microservice using
// asynchronous event loops. Implement the batching logic to efficiently write the filtered
// stream data into MongoDB."
//
// Consumes the Event Router's validated stream (validated/+/telemetry), buffers the newest
// packet per vehicle, and every BATCH_MS bulk-upserts current state into MongoDB. The MQTT
// handler only touches an in-memory Map, so ingestion never blocks on database I/O.

import mqtt from "mqtt";
import { MongoClient } from "mongodb";
import { TelemetryBatcher } from "./batcher.js";

const MQTT_URL = process.env.MQTT_URL || "mqtt://localhost:1883";
const TOPIC_IN = process.env.TOPIC_IN || "validated/+/telemetry";
const MONGO_URL = process.env.MONGO_URL || "mongodb://localhost:27017";
const MONGO_DB = process.env.MONGO_DB || "driverless_taxi";
const MONGO_COLLECTION = process.env.MONGO_COLLECTION || "telemetry";
const BATCH_MS = Number(process.env.BATCH_MS || 5000);

const mongo = new MongoClient(MONGO_URL);
await mongo.connect();
const collection = mongo.db(MONGO_DB).collection(MONGO_COLLECTION);
console.log(`[telemetry] mongo ${MONGO_URL} db=${MONGO_DB} collection=${MONGO_COLLECTION}`);

const batcher = new TelemetryBatcher({ collection, batchMs: BATCH_MS });
batcher.start();
console.log(`[telemetry] batching window ${BATCH_MS}ms`);

const client = mqtt.connect(MQTT_URL, { reconnectPeriod: 2000 });

client.on("connect", () => {
  console.log(`[telemetry] connected to ${MQTT_URL}`);
  client.subscribe(TOPIC_IN, { qos: 0 }, (err) => {
    if (err) {
      console.error("[telemetry] subscribe failed:", err.message);
      process.exit(1);
    }
    console.log(`[telemetry] subscribed to ${TOPIC_IN}`);
  });
});

client.on("message", (topic, buf) => {
  let pkt;
  try {
    pkt = JSON.parse(buf.toString());
  } catch {
    console.warn(`[telemetry] skipped non-JSON on ${topic}`);
    return;
  }
  if (!pkt || typeof pkt.vehicleID !== "string" || typeof pkt.timestamp !== "number") {
    console.warn(`[telemetry] skipped malformed packet on ${topic}`);
    return;
  }
  batcher.add(pkt);
});

client.on("error", (err) => console.error("[telemetry] mqtt error:", err.message));
client.on("reconnect", () => console.log("[telemetry] reconnecting..."));

const ticker = setInterval(() => {
  const s = batcher.stats;
  console.log(
    `[telemetry] stats received=${s.received} buffered=${batcher.buffer.size} ` +
      `dropped=${s.dropped} flushes=${s.flushes} upserts=${s.upserts}`
  );
}, 10000);
ticker.unref();

let shuttingDown = false;
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`\n[telemetry] ${sig} - final flush, then exit`, batcher.stats);
    try {
      await batcher.stop();
      client.end(true);
      await mongo.close();
    } finally {
      process.exit(0);
    }
  });
}
