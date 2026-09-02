// Data access for the Dispatch service.
//
// PostgreSQL holds the fleet roster + trip records (ACID, per the plan); MongoDB holds the
// live vehicle positions written by the Telemetry service. A dispatch reads both, then
// records the trip and flips the vehicle to on_trip in one transaction.

import pg from "pg";
import { MongoClient } from "mongodb";

const { Pool } = pg;

export function createStore({ pgUrl, mongoUrl, mongoDb, mongoCollection = "telemetry" }) {
  const pool = new Pool({ connectionString: pgUrl });
  const mongo = new MongoClient(mongoUrl);
  let telemetry;

  return {
    async connect() {
      await mongo.connect();
      telemetry = mongo.db(mongoDb).collection(mongoCollection);
      await pool.query("SELECT 1");
    },

    async close() {
      await pool.end();
      await mongo.close();
    },

    async userExists(userId) {
      const r = await pool.query("SELECT 1 FROM users WHERE id = $1", [userId]);
      return r.rowCount > 0;
    },

    // Available vehicles that can seat the party, joined with their latest known position.
    // Capacity is a hard filter here; the rest of the scoring happens in select.js.
    async availableCandidates(minSeats = 1) {
      const r = await pool.query(
        `SELECT vehicle_id, vehicle_type, passenger_seats
           FROM vehicles
          WHERE status = 'available' AND passenger_seats >= $1`,
        [minSeats]
      );
      if (r.rows.length === 0) return [];

      const meta = new Map(r.rows.map((x) => [x.vehicle_id, x]));
      const docs = await telemetry
        .find({ vehicleID: { $in: [...meta.keys()] } })
        .project({ _id: 0, vehicleID: 1, vehicleType: 1, coordinates: 1, batteryLevel: 1, currentState: 1 })
        .toArray();

      return docs.map((d) => ({
        vehicleId: d.vehicleID,
        vehicleType: d.vehicleType ?? meta.get(d.vehicleID).vehicle_type,
        seats: meta.get(d.vehicleID).passenger_seats,
        lat: d.coordinates.lat,
        lon: d.coordinates.lon,
        batteryLevel: d.batteryLevel,
        currentState: d.currentState,
      }));
    },

    // Record the trip and mark the vehicle on_trip atomically. Returns null if the vehicle
    // was taken by a concurrent request (the guarded UPDATE matches no row).
    async assignTrip({ userId, vehicleId, pickup, dropoff, tripDistanceKm }) {
      const client = await pool.connect();
      try {
        await client.query("BEGIN");
        const upd = await client.query(
          "UPDATE vehicles SET status = 'on_trip' WHERE vehicle_id = $1 AND status = 'available'",
          [vehicleId]
        );
        if (upd.rowCount === 0) {
          await client.query("ROLLBACK");
          return null;
        }
        const ins = await client.query(
          `INSERT INTO rides
             (user_id, vehicle_id, status, pickup_lat, pickup_lon,
              dropoff_lat, dropoff_lon, distance_km, assigned_at)
           VALUES ($1, $2, 'assigned', $3, $4, $5, $6, $7, now())
           RETURNING id, assigned_at`,
          [userId, vehicleId, pickup.lat, pickup.lon, dropoff.lat, dropoff.lon, tripDistanceKm]
        );
        await client.query("COMMIT");
        return { rideId: ins.rows[0].id, assignedAt: ins.rows[0].assigned_at };
      } catch (e) {
        await client.query("ROLLBACK");
        throw e;
      } finally {
        client.release();
      }
    },
  };
}
