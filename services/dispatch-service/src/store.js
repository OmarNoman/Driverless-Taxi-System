// Data access for the Dispatch service.
//
// PostgreSQL holds the fleet roster + trip records (ACID, per the plan); MongoDB holds the
// live vehicle positions written by the Telemetry service. A dispatch reads both, then
// records the trip and flips the vehicle to on_trip in one transaction.
//
// 6.4HD: availableCandidates() - the only read-heavy path in the whole system - reads
// from a separate Postgres read replica when PG_READ_URL is configured (AWS only);
// assignTrip()'s writes always go to the primary.

import pg from "pg";
import { MongoClient } from "mongodb";
import Redis from "ioredis";

const { Pool } = pg;

// Cache-aside TTL for availableCandidates(). assignTrip's guarded UPDATE (status =
// 'available') already makes a stale read safe - the worst case is a 409 the client
// already handles as "vehicle just taken, retry" - so this TTL only bounds how often
// that retry path fires, not correctness.
const CACHE_TTL_S = 3;

// Highest passenger_seats value any dispatchable vehicle can have (db/postgres/seed-fleet.sql:
// sedan 4, van 7; the bus is 40 seats but is never 'available'). The fleet is this tiny for
// the whole project, so explicit key enumeration on invalidation is fine here - a demo-scale
// simplification, not a pattern that would survive a real fleet size.
const MAX_CACHEABLE_SEATS = 7;

// 6.4HD: pgReadUrl is optional and defaults to pgUrl - zero env-var changes needed if
// the read replica isn't deployed. A distinct readPool is only created when the two
// URLs actually differ; assignTrip's UPDATE/INSERT always stay on the primary `pool`.
export function createStore({ pgUrl, pgReadUrl = pgUrl, mongoUrl, mongoDb, mongoCollection = "telemetry", redisUrl }) {
  const pool = new Pool({ connectionString: pgUrl });
  const readPool = pgReadUrl === pgUrl ? pool : new Pool({ connectionString: pgReadUrl });
  const mongo = new MongoClient(mongoUrl);
  const redis = new Redis(redisUrl);
  redis.on("error", (e) => console.error("[store] redis error:", e.message));
  let telemetry;

  return {
    async connect() {
      await mongo.connect();
      telemetry = mongo.db(mongoDb).collection(mongoCollection);
      await pool.query("SELECT 1");
      if (readPool !== pool) await readPool.query("SELECT 1");
    },

    async close() {
      await pool.end();
      if (readPool !== pool) await readPool.end();
      await mongo.close();
      redis.disconnect();
    },

    async userExists(userId) {
      const r = await pool.query("SELECT 1 FROM users WHERE id = $1", [userId]);
      return r.rowCount > 0;
    },

    // Available vehicles that can seat the party, joined with their latest known position.
    // Capacity is a hard filter here; the rest of the scoring happens in select.js.
    // Cache-aside: a hit skips both the Postgres and Mongo round trips entirely. Logged
    // (not just returned) so a hit ratio can be computed from CloudWatch Logs under load,
    // the same way Mellati et al. report theirs.
    async availableCandidates(minSeats = 1) {
      const cacheKey = `avail:${minSeats}`;
      const cached = await redis.get(cacheKey).catch(() => null);
      if (cached !== null) {
        console.log(`[store] cache hit ${cacheKey}`);
        return JSON.parse(cached);
      }
      console.log(`[store] cache miss ${cacheKey}`);

      const r = await readPool.query(
        `SELECT vehicle_id, vehicle_type, passenger_seats
           FROM vehicles
          WHERE status = 'available' AND passenger_seats >= $1`,
        [minSeats]
      );
      if (r.rows.length === 0) {
        await redis.setex(cacheKey, CACHE_TTL_S, "[]").catch(() => {});
        return [];
      }

      const meta = new Map(r.rows.map((x) => [x.vehicle_id, x]));
      const docs = await telemetry
        .find({ vehicleID: { $in: [...meta.keys()] } })
        .project({ _id: 0, vehicleID: 1, vehicleType: 1, coordinates: 1, batteryLevel: 1, currentState: 1 })
        .toArray();

      const candidates = docs.map((d) => ({
        vehicleId: d.vehicleID,
        vehicleType: d.vehicleType ?? meta.get(d.vehicleID).vehicle_type,
        seats: meta.get(d.vehicleID).passenger_seats,
        lat: d.coordinates.lat,
        lon: d.coordinates.lon,
        batteryLevel: d.batteryLevel,
        currentState: d.currentState,
      }));

      await redis.setex(cacheKey, CACHE_TTL_S, JSON.stringify(candidates)).catch(() => {});
      return candidates;
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
        const keys = Array.from({ length: MAX_CACHEABLE_SEATS }, (_, i) => `avail:${i + 1}`);
        await redis.del(...keys).catch(() => {});
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
