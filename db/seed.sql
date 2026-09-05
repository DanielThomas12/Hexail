-- Test fixtures: one route (A-C-D-E-F-B), one trip, one coach, five seats.
-- Used to validate the schema's constraints before any application code exists.

INSERT INTO stations (code, name) VALUES
  ('A', 'Alpha Junction'),
  ('C', 'Charlie Town'),
  ('D', 'Delta City'),
  ('E', 'Echo Falls'),
  ('F', 'Foxwood'),
  ('B', 'Bravo Terminal');

INSERT INTO trains (train_number, name) VALUES ('12345', 'Test Express');

-- Route: A(1) - C(2) - D(3) - E(4) - F(5) - B(6), giving legs 1 through 5
INSERT INTO train_stops (train_id, sequence_no, station_id)
SELECT t.train_id, s.seq, st.station_id
FROM trains t, (VALUES (1,'A'),(2,'C'),(3,'D'),(4,'E'),(5,'F'),(6,'B')) AS s(seq, code)
JOIN stations st ON st.code = s.code
WHERE t.train_number = '12345';

INSERT INTO trips (train_id, service_date, freeze_at)
SELECT train_id, CURRENT_DATE + 1, (CURRENT_DATE + 1 + TIME '08:00') - INTERVAL '4 hours'
FROM trains WHERE train_number = '12345';

INSERT INTO coaches (trip_id, coach_number, class)
SELECT trip_id, 'C1', 'SL' FROM trips
WHERE train_id = (SELECT train_id FROM trains WHERE train_number = '12345');

INSERT INTO seats (coach_id, seat_number, is_accessible)
SELECT coach_id, seat_num, FALSE
FROM coaches, (VALUES ('12'),('13'),('15'),('18'),('20')) AS s(seat_num)
WHERE coach_number = 'C1';
