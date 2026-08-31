-- Week 6 - development-only test data.
--
-- Unlike seed-fleet.sql (static fleet reference data the plan calls for), this is just a
-- convenience so the Dispatch service's POST /rides has a valid userId to use in local
-- demos and tests. Real passenger accounts are created by the application at runtime.
-- With users.id being GENERATED ALWAYS AS IDENTITY, this demo user gets id 1.

INSERT INTO users (full_name, email)
VALUES ('Demo Passenger', 'demo@example.com')
ON CONFLICT (email) DO NOTHING;
