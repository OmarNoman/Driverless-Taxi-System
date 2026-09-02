-- Static fleet reference data.
--
-- One vehicle of each type the plan names (sedan, van, bus), matching the identifiers the
-- Node-RED simulator publishes. home_node_id is a graph/melbourne.json node id and must
-- match the simulator's per-vehicle config. Only the "static fleet information" the plan
-- calls for is seeded here; users, rides and payments are runtime data.
--
--   TAXI-001  sedan  4 seats   home Melbourne CBD (0)    dispatchable
--   TAXI-002  van    7 seats   home Sunshine     (18)    dispatchable
--   TAXI-003  bus    40 seats  loop node         (13)    NOT dispatchable - runs a fixed
--                                                        route, so its status is 'on_trip'
--                                                        and Dispatch never assigns it.

INSERT INTO vehicles (vehicle_id, vehicle_type, passenger_seats, registration, status, home_node_id) VALUES
    ('TAXI-001', 'sedan',  4, 'DTX-001', 'available', 0),
    ('TAXI-002', 'van',    7, 'DTX-002', 'available', 18),
    ('TAXI-003', 'bus',   40, 'DTX-003', 'on_trip',   13)
ON CONFLICT (vehicle_id) DO NOTHING;
