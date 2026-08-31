// Week 4 - Event Router payload validation.
//
// Kept separate from index.js so the validation rules can be unit-tested without a broker.
// The schema is schema/telemetry.schema.json at the repo root - the same file the MongoDB
// telemetry collection uses as its validator, so "valid to the Event Router" and "valid to
// the database" mean the same thing.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import Ajv from "ajv";

const here = dirname(fileURLToPath(import.meta.url));

export const SCHEMA_PATH =
  process.env.SCHEMA_PATH || resolve(here, "../../../schema/telemetry.schema.json");

export function loadValidator(schemaPath = SCHEMA_PATH) {
  const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
  const ajv = new Ajv({ allErrors: true });
  return ajv.compile(schema);
}

// Validate one raw MQTT message.
// Returns { ok: true, payload } or { ok: false, reason }.
export function checkMessage(topic, raw, validate) {
  let payload;
  try {
    payload = JSON.parse(typeof raw === "string" ? raw : raw.toString());
  } catch {
    return { ok: false, reason: "payload is not valid JSON" };
  }

  if (!validate(payload)) {
    const reason = validate.errors
      .map((e) => `${e.instancePath || "/"} ${e.message}`)
      .join("; ");
    return { ok: false, reason };
  }

  // fleet/<vehicleID>/telemetry - the id in the topic must match the id in the body
  const idFromTopic = String(topic).split("/")[1];
  if (idFromTopic !== payload.vehicleID) {
    return {
      ok: false,
      reason: `topic vehicle "${idFromTopic}" does not match payload vehicleID "${payload.vehicleID}"`,
    };
  }

  return { ok: true, payload };
}
