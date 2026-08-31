-- Week 3 - static fleet reference data.
--
-- Three vehicles matching the identifiers the Node-RED simulator publishes (Week 2), so the
-- relational side has a fleet to reason about and the Dispatch service (Week 6) has rows to
-- filter. Only the "static fleet information" the plan calls for is seeded here - users,
-- rides and payments are runtime data and are left empty.

INSERT INTO vehicles (vehicle_id, vehicle_type, passenger_seats, registration, status) VALUES
    ('TAXI-001', 'sedan', 4, 'DTX-001', 'available'),
    ('TAXI-002', 'van',   7, 'DTX-002', 'available'),
    ('TAXI-003', 'sedan', 4, 'DTX-003', 'available')
ON CONFLICT (vehicle_id) DO NOTHING;
