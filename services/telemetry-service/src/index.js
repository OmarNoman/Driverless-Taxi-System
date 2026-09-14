// Telemetry microservice
//
// Plan (Project Plan, Week 5): "Develop the Node.js Telemetry microservice using
// asynchronous event loops. Implement the batching logic to efficiently write the filtered
// stream data into MongoDB."
//
// Consumes the Event Router's validated stream: over MQTT (validated/+/telemetry) locally,
// or over SQS in AWS (Week 8, SQS_QUEUE_URL set), since the plan requires an SQS buffer
// "between the MQTT broker and the database". The MQTT/SQS handler only touches in-memory
// buffers, so ingestion never blocks on database I/O. Every BATCH_MS the buffers are
// flushed: the newest packet per vehicle is bulk-upserted into `telemetry` (current state,
// last-write-wins), and every packet is appended to `telemetry_history` (append-only,
// TTL-pruned).
//
// In SQS mode a message is only deleted from the queue after the flush it was part of
// durably lands in Mongo (not immediately on receipt), so a crash mid-batch-window no
// longer loses that window's data - this is what actually delivers the plan's "ensuring
// there is zero data loss", not just matching today's MQTT QoS-0 behaviour.

import mqtt from "mqtt";
import { MongoClient } from "mongodb";
import { SQSClient, ReceiveMessageCommand, DeleteMessageBatchCommand } from "@aws-sdk/client-sqs";
import { TelemetryBatcher } from "./batcher.js";

const MQTT_URL = process.env.MQTT_URL || "mqtt://localhost:1883";
const TOPIC_IN = process.env.TOPIC_IN || "validated/+/telemetry";
const MONGO_URL = process.env.MONGO_URL || "mongodb://localhost:27017";
const MONGO_DB = process.env.MONGO_DB || "driverless_taxi";
const MONGO_COLLECTION = process.env.MONGO_COLLECTION || "telemetry";
const MONGO_HISTORY = process.env.MONGO_HISTORY || "telemetry_history";
const BATCH_MS = Number(process.env.BATCH_MS || 5000);
const SQS_QUEUE_URL = process.env.SQS_QUEUE_URL || null;

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

function packetIsValid(pkt) {
  return Boolean(pkt) && typeof pkt.vehicleID === "string" && typeof pkt.timestamp === "number";
}

let shuttingDown = false;
let stopIngestion = async () => {};
let client = null; // MQTT client - only created outside SQS mode

if (SQS_QUEUE_URL) {
  const sqs = new SQSClient({});
  console.log(`[telemetry] consuming SQS ${SQS_QUEUE_URL} (MQTT validated-stream subscribe skipped)`);
  console.log(`[telemetry] batching window ${BATCH_MS}ms (SQS mode, delete-after-flush)`);

  let pendingReceipts = []; // receipt handles for packets already handed to the batcher this window

  async function flushAndAck() {
    const receipts = pendingReceipts;
    pendingReceipts = [];
    try {
      await batcher.flush();
      for (let i = 0; i < receipts.length; i += 10) {
        const chunk = receipts.slice(i, i + 10);
        await sqs
          .send(
            new DeleteMessageBatchCommand({
              QueueUrl: SQS_QUEUE_URL,
              Entries: chunk.map((h, idx) => ({ Id: String(idx), ReceiptHandle: h })),
            })
          )
          .catch((e) => console.error("[telemetry] sqs delete failed:", e.message));
      }
    } catch (e) {
      // flush failed - the batcher already restored its own buffers, do the same here so
      // these receipts get retried (and deleted) on the next successful flush instead of
      // being lost or left to expire only via the queue's own visibility timeout
      pendingReceipts = receipts.concat(pendingReceipts);
      console.error("[telemetry] flush error:", e.message);
    }
  }

  const flushTimer = setInterval(() => {
    flushAndAck();
  }, BATCH_MS);
  flushTimer.unref?.();

  (async function pollLoop() {
    while (!shuttingDown) {
      let Messages;
      try {
        ({ Messages } = await sqs.send(
          new ReceiveMessageCommand({
            QueueUrl: SQS_QUEUE_URL,
            MaxNumberOfMessages: 10,
            WaitTimeSeconds: 20,
          })
        ));
      } catch (e) {
        console.error("[telemetry] sqs receive failed:", e.message);
        continue;
      }
      for (const m of Messages || []) {
        let pkt;
        try {
          pkt = JSON.parse(m.Body);
        } catch {
          console.warn("[telemetry] skipped non-JSON SQS message");
          continue;
        }
        if (!packetIsValid(pkt)) {
          console.warn("[telemetry] skipped malformed SQS message");
          continue;
        }
        batcher.add(pkt);
        pendingReceipts.push(m.ReceiptHandle);
      }
    }
  })();

  stopIngestion = async () => {
    clearInterval(flushTimer);
    await flushAndAck();
  };
} else {
  batcher.start();
  console.log(`[telemetry] batching window ${BATCH_MS}ms`);
  client = mqtt.connect(MQTT_URL, { reconnectPeriod: 2000 });

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
    if (!packetIsValid(pkt)) {
      console.warn(`[telemetry] skipped malformed packet on ${topic}`);
      return;
    }
    batcher.add(pkt);
  });

  client.on("error", (err) => console.error("[telemetry] mqtt error:", err.message));
  client.on("reconnect", () => console.log("[telemetry] reconnecting..."));

  stopIngestion = async () => {
    await batcher.stop();
  };
}

const ticker = setInterval(() => {
  const s = batcher.stats;
  console.log(
    `[telemetry] stats received=${s.received} buffered=${batcher.buffer.size} ` +
      `dropped=${s.dropped} flushes=${s.flushes} upserts=${s.upserts} history=${s.history}`
  );
}, 10000);
ticker.unref();

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`\n[telemetry] ${sig} - final flush, then exit`, batcher.stats);
    try {
      await stopIngestion();
      if (client) client.end(true);
      await mongo.close();
    } finally {
      process.exit(0);
    }
  });
}
