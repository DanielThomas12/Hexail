-- ============================================================
-- Dynamic Segment-Based Train Booking — Core Schema (PostgreSQL)
-- ============================================================
-- Design notes are inline as comments, each tagged with the
-- issue from our earlier discussion that it addresses.

-- ---------- Reference data ----------

CREATE TABLE stations (
    station_id      BIGSERIAL PRIMARY KEY,
    code            TEXT UNIQUE NOT NULL,      -- e.g. 'NDLS'
    name            TEXT NOT NULL
);

CREATE TABLE trains (
    train_id        BIGSERIAL PRIMARY KEY,
    train_number    TEXT UNIQUE NOT NULL,
    name            TEXT NOT NULL
);

-- The ordered stop sequence a train follows. This is the template;
-- legs are the gaps between consecutive sequence_no values.
CREATE TABLE train_stops (
    train_id        BIGINT NOT NULL REFERENCES trains(train_id),
    sequence_no     INT NOT NULL,               -- 1, 2, 3 ... in route order
    station_id      BIGINT NOT NULL REFERENCES stations(station_id),
    PRIMARY KEY (train_id, sequence_no)
);
-- leg N = travel FROM the stop at sequence_no=N TO sequence_no=N+1

-- ---------- Trip = one specific date's run of a train ----------
-- IMPORTANT: seat inventory is scoped to a trip, not to the train
-- generically -- the same train number runs a fresh, independent
-- inventory every service day.
CREATE TABLE trips (
    trip_id         BIGSERIAL PRIMARY KEY,
    train_id        BIGINT NOT NULL REFERENCES trains(train_id),
    service_date    DATE NOT NULL,
    status          TEXT NOT NULL DEFAULT 'scheduled'
                        CHECK (status IN ('scheduled','departed','cancelled')),
    -- Issue #5 fix: hard freeze point. No reallocation job may run,
    -- and no new multi-seat itinerary may be generated, after this
    -- timestamp -- only exact single-seat holds already in flight
    -- can complete. Enforce in application logic at this boundary.
    freeze_at       TIMESTAMPTZ NOT NULL,
    UNIQUE (train_id, service_date)
);

-- ---------- Physical inventory for a trip ----------

CREATE TABLE coaches (
    coach_id        BIGSERIAL PRIMARY KEY,
    trip_id         BIGINT NOT NULL REFERENCES trips(trip_id),
    coach_number    TEXT NOT NULL,
    class           TEXT NOT NULL,              -- 'SL', '3A', '2A', 'CC' ...
    UNIQUE (trip_id, coach_number)
);

CREATE TABLE seats (
    seat_id         BIGSERIAL PRIMARY KEY,
    coach_id        BIGINT NOT NULL REFERENCES coaches(coach_id),
    seat_number     TEXT NOT NULL,
    -- Issue #3 fix: accessible/reserved seats are flagged so the
    -- allocation algorithm can exclude them from the dynamic
    -- multi-seat pool by default.
    is_accessible   BOOLEAN NOT NULL DEFAULT FALSE,
    UNIQUE (coach_id, seat_number)
);

-- ---------- The heart of it: per-leg seat state ----------
-- Two separate tables, not one tri-state column. This is deliberate:
-- committed bookings and in-flight holds have different lifecycles
-- and different concurrency guarantees (Issue #2 fix).

-- Confirmed, committed legs. The UNIQUE constraint IS the
-- double-booking guard -- the database itself refuses to let two
-- segments claim the same seat on the same leg, no app-level race
-- window possible.
CREATE TABLE seat_leg_bookings (
    id                  BIGSERIAL PRIMARY KEY,
    seat_id             BIGINT NOT NULL REFERENCES seats(seat_id),
    leg_sequence        INT NOT NULL,           -- matches train_stops.sequence_no
    booking_segment_id  BIGINT NOT NULL,        -- FK added after booking_segments exists
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (seat_id, leg_sequence)
);

-- Short-lived holds taken during checkout. Same unique-constraint
-- trick prevents two simultaneous checkouts from holding the same
-- seat-leg. A cleanup job (or a check at claim time) discards rows
-- past expires_at. (Issue #2 fix.)
CREATE TABLE seat_leg_holds (
    id              BIGSERIAL PRIMARY KEY,
    seat_id         BIGINT NOT NULL REFERENCES seats(seat_id),
    leg_sequence    INT NOT NULL,
    hold_token      UUID NOT NULL,              -- ties all legs of one checkout together
    expires_at      TIMESTAMPTZ NOT NULL,
    UNIQUE (seat_id, leg_sequence)
);
CREATE INDEX idx_holds_expiry ON seat_leg_holds (expires_at);

-- ---------- Bookings ----------

CREATE TABLE bookings (
    booking_id          BIGSERIAL PRIMARY KEY,
    pnr                 TEXT UNIQUE NOT NULL,
    trip_id             BIGINT NOT NULL REFERENCES trips(trip_id),
    origin_leg_seq      INT NOT NULL,
    dest_leg_seq        INT NOT NULL CHECK (dest_leg_seq > origin_leg_seq),
    status              TEXT NOT NULL DEFAULT 'confirmed'
                            CHECK (status IN ('confirmed','waitlisted','cancelled')),
    -- Issue #7 fix: the passenger explicitly consented to this,
    -- captured at booking time rather than assumed.
    single_seat_only    BOOLEAN NOT NULL DEFAULT FALSE,
    max_switches        INT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Issue #3 fix: group bookings are modeled explicitly so the
-- allocation layer can treat a whole group as one atomic
-- "keep together" request rather than packing members separately.
CREATE TABLE booking_passengers (
    id              BIGSERIAL PRIMARY KEY,
    booking_id      BIGINT NOT NULL REFERENCES bookings(booking_id),
    name            TEXT NOT NULL,
    age             INT,
    is_primary      BOOLEAN NOT NULL DEFAULT FALSE
);

-- The stitched itinerary itself: one row per contiguous seat run.
-- A single-seat booking has exactly one row here; a stitched
-- booking (seat 12 for legs 1,3-5 + seat 15 for leg 2) has three.
CREATE TABLE booking_segments (
    segment_id      BIGSERIAL PRIMARY KEY,
    booking_id      BIGINT NOT NULL REFERENCES bookings(booking_id),
    seat_id         BIGINT NOT NULL REFERENCES seats(seat_id),
    leg_start_seq   INT NOT NULL,
    leg_end_seq     INT NOT NULL CHECK (leg_end_seq >= leg_start_seq),
    sequence_no     INT NOT NULL                -- order within the journey, 1,2,3...
);

ALTER TABLE seat_leg_bookings
    ADD CONSTRAINT fk_segment
    FOREIGN KEY (booking_segment_id) REFERENCES booking_segments(segment_id);

-- Issue #7 fix: append-only trail. Every state change is a new row,
-- never an UPDATE to history -- this is what resolves a passenger
-- dispute ("my ticket says two different seats") authoritatively.
CREATE TABLE booking_audit_log (
    id              BIGSERIAL PRIMARY KEY,
    booking_id      BIGINT NOT NULL REFERENCES bookings(booking_id),
    event_type      TEXT NOT NULL,              -- 'created','segment_reassigned','cancelled','upgrade_offered', ...
    payload         JSONB NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- Helper: is a seat free across a leg range? ----------
-- Mirrors the bitmask AND-check from the allocation algorithm, but
-- against the durable source of truth. In production this same
-- check is mirrored as an in-memory bitmask in Redis (keyed by
-- trip_id + seat_id) for the hot search path -- Issue #8, scale.
CREATE OR REPLACE FUNCTION is_seat_free(
    p_seat_id BIGINT, p_leg_start INT, p_leg_end INT
) RETURNS BOOLEAN AS $$
    SELECT NOT EXISTS (
        SELECT 1 FROM seat_leg_bookings
        WHERE seat_id = p_seat_id
          AND leg_sequence >= p_leg_start AND leg_sequence < p_leg_end
    ) AND NOT EXISTS (
        SELECT 1 FROM seat_leg_holds
        WHERE seat_id = p_seat_id
          AND leg_sequence >= p_leg_start AND leg_sequence < p_leg_end
          AND expires_at > now()
    );
$$ LANGUAGE sql STABLE;

-- ---------- Indexes for the common query paths ----------
CREATE INDEX idx_bookings_trip_status ON bookings (trip_id, status);
CREATE INDEX idx_segments_booking ON booking_segments (booking_id);
CREATE INDEX idx_seat_leg_bookings_leg ON seat_leg_bookings (leg_sequence);
