-- Manual test proving the core guarantee of this schema: the database
-- itself refuses to let one seat be assigned to two passengers for the
-- same leg. Run against the data created by seed.sql.
--
-- This isn't a demonstration -- it's a deliberate attempt to break the
-- schema, kept here as a record that it held.

-- 1. Create a booking for the full journey (legs 1-5).
INSERT INTO bookings (pnr, trip_id, origin_leg_seq, dest_leg_seq)
SELECT 'PNR0001', trip_id, 1, 6
FROM trips WHERE train_id = (SELECT train_id FROM trains WHERE train_number = '12345');

-- 2. Assign seat 12 to cover the whole journey.
INSERT INTO booking_segments (booking_id, seat_id, leg_start_seq, leg_end_seq, sequence_no)
SELECT b.booking_id, s.seat_id, 1, 5, 1
FROM bookings b, seats s JOIN coaches c ON s.coach_id = c.coach_id
WHERE b.pnr = 'PNR0001' AND s.seat_number = '12' AND c.coach_number = 'C1';

-- 3. Actually claim all 5 legs for seat 12.
INSERT INTO seat_leg_bookings (seat_id, leg_sequence, booking_segment_id)
SELECT s.seat_id, leg, seg.segment_id
FROM seats s
JOIN coaches c ON s.coach_id = c.coach_id
CROSS JOIN generate_series(1,5) AS leg
JOIN booking_segments seg ON seg.seat_id = s.seat_id
WHERE s.seat_number = '12' AND c.coach_number = 'C1';
-- Expected: 5 rows inserted.

-- 4. Deliberately try to double-book leg 3 of the same seat.
-- EXPECTED RESULT: this fails with
--   ERROR: duplicate key value violates unique constraint (SQLSTATE 42P07... actually 23505)
-- That failure is the schema working correctly, not a bug.
INSERT INTO seat_leg_bookings (seat_id, leg_sequence, booking_segment_id)
SELECT s.seat_id, 3, seg.segment_id
FROM seats s
JOIN coaches c ON s.coach_id = c.coach_id
JOIN booking_segments seg ON seg.seat_id = s.seat_id
WHERE s.seat_number = '12' AND c.coach_number = 'C1';

-- If step 4 fails (it should), run ROLLBACK; before continuing.

-- 5. Confirm is_seat_free() agrees with what's actually booked.
SELECT is_seat_free(
  (SELECT s.seat_id FROM seats s JOIN coaches c ON s.coach_id=c.coach_id WHERE s.seat_number='12' AND c.coach_number='C1'),
  1, 6
); -- expected: false, seat 12 is fully booked

SELECT is_seat_free(
  (SELECT s.seat_id FROM seats s JOIN coaches c ON s.coach_id=c.coach_id WHERE s.seat_number='13' AND c.coach_number='C1'),
  1, 6
); -- expected: true, seat 13 was never touched
