// Week 3 - Data Layer: MongoDB telemetry collection with schema validation.
//
// Plan (Implementation Plan): telemetry is collected as JSON documents holding timestamp,
// vehicleID, coordinates, speed, battery level and current state, stored in MongoDB for its
// flexible schema and high write-throughput.
//
// Design note: this collection holds the CURRENT state per vehicle (one document each,
// upserted), not an append-only history. That matches the Week 5 Telemetry service (bulk
// upserts) and the plan's last-write-wins rule - a write is dropped if its timestamp is
// older than the stored one. Hence the unique index on vehicleID.
//
// Runs automatically via /docker-entrypoint-initdb.d on first container start. To apply by
// hand: mongosh "mongodb://localhost:27017/driverless_taxi" db/mongo/init-telemetry.js

const target = db.getSiblingDB("driverless_taxi");

const telemetrySchema = {
  bsonType: "object",
  required: ["vehicleID", "coordinates", "speed", "batteryLevel", "currentState", "timestamp"],
  additionalProperties: false,
  properties: {
    _id: {},
    vehicleID: {
      bsonType: "string",
      description: "vehicle identifier, e.g. 'TAXI-001'"
    },
    coordinates: {
      bsonType: "object",
      required: ["lat", "lon"],
      additionalProperties: false,
      properties: {
        lat: { bsonType: "number", minimum: -90, maximum: 90 },
        lon: { bsonType: "number", minimum: -180, maximum: 180 }
      }
    },
    speed: { bsonType: "number", minimum: 0, description: "km/h" },
    batteryLevel: { bsonType: "number", minimum: 0, maximum: 100, description: "percent" },
    currentState: { enum: ["driving", "parked"] },
    seatWeightKg: {
      bsonType: "number",
      minimum: 0,
      description: "optional - seat-weight sensor, the union of the plan's two sensor lists"
    },
    timestamp: {
      bsonType: "number",
      minimum: 0,
      description: "Unix epoch milliseconds, stamped at the simulated edge"
    }
  }
};

if (target.getCollectionInfos({ name: "telemetry" }).length === 0) {
  target.createCollection("telemetry", {
    validator: { $jsonSchema: telemetrySchema },
    validationLevel: "strict",
    validationAction: "error"
  });
} else {
  target.runCommand({
    collMod: "telemetry",
    validator: { $jsonSchema: telemetrySchema },
    validationLevel: "strict",
    validationAction: "error"
  });
}

target.telemetry.createIndex({ vehicleID: 1 }, { name: "vehicle_unique", unique: true });
target.telemetry.createIndex({ timestamp: -1 }, { name: "by_time" });

print("driverless_taxi.telemetry ready - schema validation + indexes applied");
