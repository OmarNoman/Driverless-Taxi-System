// Week 4 - Event Router
//
// Plan (Project Plan, Week 4): "Develop the initial Node.js Event Router to consume the raw
// vehicle telemetry stream and validate message payloads."
//
// This week's scope: subscribe to the telemetry topic, validate each payload against the
// shared schema, and log accepted vs rejected with the reason. Valid packets are
// re-published on a "validated/<vehicleID>/telemetry" topic so the Week 5 Telemetry service
// has a clean stream to consume. It does NOT write to a database - that is Week 5.
//
// Week 8: when SQS_QUEUE_URL is set (AWS only), every validated packet is additionally
// sent to that queue, the SQS buffer the plan requires "between the MQTT broker and the
// database". Locally (SQS_QUEUE_URL unset) this is a no-op - the MQTT publish above is
// unchanged either way.

import mqtt from "mqtt";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { loadValidator, checkMessage, SCHEMA_PATH } from "./validator.js";

const BROKER_URL = process.env.MQTT_URL || "mqtt://localhost:1883";
const TOPIC_IN = process.env.TOPIC_IN || "fleet/+/telemetry";
const OUT_PREFIX = process.env.TOPIC_OUT_PREFIX || "validated";
const SQS_QUEUE_URL = process.env.SQS_QUEUE_URL || null;

const validate = loadValidator();
const stats = { received: 0, accepted: 0, rejected: 0 };
const sqs = SQS_QUEUE_URL ? new SQSClient({}) : null;

console.log(`[event-router] schema ${SCHEMA_PATH}`);
if (sqs) console.log(`[event-router] also publishing validated packets to SQS ${SQS_QUEUE_URL}`);
const client = mqtt.connect(BROKER_URL, { reconnectPeriod: 2000 });

client.on("connect", () => {
  console.log(`[event-router] connected to ${BROKER_URL}`);
  client.subscribe(TOPIC_IN, { qos: 0 }, (err) => {
    if (err) {
      console.error("[event-router] subscribe failed:", err.message);
      process.exit(1);
    }
    console.log(`[event-router] subscribed to ${TOPIC_IN}`);
  });
});

client.on("message", (topic, buf) => {
  stats.received++;
  const result = checkMessage(topic, buf, validate);

  if (!result.ok) {
    stats.rejected++;
    console.warn(`[event-router] REJECT ${topic}: ${result.reason}`);
    return;
  }

  stats.accepted++;
  const p = result.payload;
  const body = JSON.stringify(p);
  client.publish(`${OUT_PREFIX}/${p.vehicleID}/telemetry`, body, { qos: 0 });
  if (sqs) {
    sqs
      .send(new SendMessageCommand({ QueueUrl: SQS_QUEUE_URL, MessageBody: body }))
      .catch((e) => console.error("[event-router] sqs send failed:", e.message));
  }
  console.log(
    `[event-router] OK     ${p.vehicleID} state=${p.currentState} ` +
      `batt=${p.batteryLevel} speed=${p.speed}`
  );
});

client.on("error", (err) => console.error("[event-router] mqtt error:", err.message));
client.on("reconnect", () => console.log("[event-router] reconnecting..."));

const ticker = setInterval(() => {
  console.log(
    `[event-router] stats received=${stats.received} ` +
      `accepted=${stats.accepted} rejected=${stats.rejected}`
  );
}, 10000);
ticker.unref();

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    console.log(`\n[event-router] ${sig} received - final stats`, stats);
    client.end(true, () => process.exit(0));
  });
}
