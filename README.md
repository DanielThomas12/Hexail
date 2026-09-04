# Dynamic Train Seat Booking System

A train ticket booking system that solves the "phantom sold out" problem —
where a seat shows as unavailable for a whole route even though the
passenger sitting in it is only travelling a short leg of the journey.

Instead of blocking a full-journey passenger just because *some* leg of
their route is taken, this system tracks seat availability **per leg**,
and when a single seat isn't free the whole way, it can assign the
passenger across multiple physical seats for different segments of the
same journey — shown to them up front, before they confirm.

## Status
🚧 In progress — student portfolio project.

## Stack
- **Database:** PostgreSQL, hosted on [Neon](https://neon.tech)
- **Backend:** TBD
- **Frontend:** TBD

## Project structure
```
db/
  schema.sql    -- core database schema, with design notes inline
```

## Setup
1. Create a Neon project and copy the connection string.
2. Copy `.env.example` to `.env` and fill in `DATABASE_URL`.
3. Run the schema against your database:
   ```
   psql "$DATABASE_URL" -f db/schema.sql
   ```

## Design notes
See the inline comments in `db/schema.sql` for the reasoning behind each
table. Highlights:
- Seat availability is tracked per leg, not per whole journey, via a
  `seat_leg_bookings` table.
- Double-booking is prevented at the database level with a
  `UNIQUE (seat_id, leg_sequence)` constraint — not just application logic.
- Every booking change is recorded in an append-only `booking_audit_log`
  rather than overwriting history, so any dispute has a clear record.
