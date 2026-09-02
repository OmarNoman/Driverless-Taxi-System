-- Week 3 - Data Layer: PostgreSQL relational schema for ride and user management.
--
-- Plan (Implementation Plan): a relational SQL store for "user accounts, ride histories,
-- billing statuses, and static fleet information", chosen for strict ACID compliance so a
-- transactional action such as booking a ride is not lost.
--
-- Applied automatically by the Postgres container via /docker-entrypoint-initdb.d on first
-- boot. To apply by hand against a running instance:
--   psql -h localhost -U dtx -d driverless_taxi -f db/postgres/schema.sql

BEGIN;

-- ---------------------------------------------------------------------------
-- Static fleet information
-- vehicle_id is the same identifier the Node-RED simulator emits (e.g. 'TAXI-001').
-- status is the dispatch-facing availability flag; live position and battery live in
-- MongoDB telemetry, not here.
-- home_node_id is the graph/melbourne.json node the vehicle idles at (or, for a bus, a
-- node on its fixed loop). The Node-RED simulator uses the same values; keep them in sync.
-- ---------------------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id      text PRIMARY KEY,
    vehicle_type    text NOT NULL DEFAULT 'sedan'
                        CHECK (vehicle_type IN ('sedan', 'van', 'bus')),
    passenger_seats smallint NOT NULL CHECK (passenger_seats > 0),
    registration    text NOT NULL UNIQUE,
    status          text NOT NULL DEFAULT 'available'
                        CHECK (status IN ('available', 'on_trip', 'charging', 'maintenance', 'offline')),
    home_node_id    smallint NOT NULL CHECK (home_node_id BETWEEN 0 AND 20),
    commissioned_on date NOT NULL DEFAULT CURRENT_DATE
);

-- ---------------------------------------------------------------------------
-- User accounts
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   text NOT NULL,
    email       text NOT NULL UNIQUE,
    phone       text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Ride histories
-- One row per ride request through its whole lifecycle. vehicle_id stays null until the
-- Dispatch service (Week 6) assigns one.
-- ---------------------------------------------------------------------------
CREATE TABLE rides (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id       bigint NOT NULL REFERENCES users (id),
    vehicle_id    text REFERENCES vehicles (vehicle_id),
    status        text NOT NULL DEFAULT 'requested'
                      CHECK (status IN ('requested', 'assigned', 'in_progress', 'completed', 'cancelled')),
    pickup_lat    numeric(9,6) NOT NULL,
    pickup_lon    numeric(9,6) NOT NULL,
    dropoff_lat   numeric(9,6) NOT NULL,
    dropoff_lon   numeric(9,6) NOT NULL,
    distance_km   numeric(8,3),
    requested_at  timestamptz NOT NULL DEFAULT now(),
    assigned_at   timestamptz,
    completed_at  timestamptz
);

CREATE INDEX rides_user_id_idx    ON rides (user_id);
CREATE INDEX rides_vehicle_id_idx ON rides (vehicle_id);
CREATE INDEX rides_status_idx     ON rides (status);

-- ---------------------------------------------------------------------------
-- Billing statuses
-- One payment record per ride, tracking where that charge is in its lifecycle.
-- ---------------------------------------------------------------------------
CREATE TABLE payments (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ride_id     bigint NOT NULL UNIQUE REFERENCES rides (id),
    amount      numeric(10,2) NOT NULL CHECK (amount >= 0),
    currency    char(3) NOT NULL DEFAULT 'AUD',
    status      text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'authorized', 'paid', 'failed', 'refunded')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX payments_status_idx ON payments (status);

COMMIT;
