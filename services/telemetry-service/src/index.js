// Telemetry microservice
//
// Plan (Project Plan, Week 5): "Develop the Node.js Telemetry microservice using
// asynchronous event loops. Implement the batching logic to efficiently write the filtered
// stream data into MongoDB."
//
// Consumes the Event Router's validated stream (validated/+/telemetry). The MQTT handler
// only touches in-memory buffers, so ingestion never blocks on database I/O. Every
// BATCH_MS the buffers are flushed: the newest packet per vehicle is bulk-upserted into
// `telemetry` (current state, last-write-wins), and every packet is appended to
// `telemetry_history` (append-only, TTL-pruned).

import mqtt from "mqtt";
import { MongoClient } from "mongodb";
import { TelemetryBatcher } from "./batcher.js";

const MQTT_URL = process.env.MQTT_URL || "mqtt://localhost:1883";
const TOPIC_IN = process.env.TOPIC_IN || "validated/+/telemetry";
const MONGO_URL = process.env.MONGO_URL || "mongodb://localhost:27017";
const MONGO_DB = process.env.MONGO_DB || "driverless_taxi";
const MONGO_COLLECTION = process.env.MONGO_COLLECTION || "telemetry";
const MONGO_HISTORY = process.env.MONGO_HISTORY || "telemetry_history";
const BATCH_MS = Number(process.env.BATCH_MS || 5000);

const mongo = new MongoClient(MONGO_URL);
await mongo.connect();
const db = mongo.db(MONGO_DB);
const collection = db.collection(MONGO_COLLECTION);
const historyCollection = db.collection(MONGO_HISTORY);
console.log(
  `[telemetry] mongo ${MONGO_URL} db=${MONGO_DB} ` +
    `collections=${MONGO_COLLECTION},${MONGO_HISTORY}`
);

const batcher = new TelemetryBatcher({ collection, historyCollection, batchMs: BATCH_MS });
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
      `dropped=${s.dropped} flushes=${s.flushes} upserts=${s.upserts} history=${s.history}`
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
