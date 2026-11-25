-- =====================================================================
-- ICT371 Advanced Database | Question 5: Hostel Room Allocation
-- Name: ________________ | Student number: ____________ | PostgreSQL 16 (PL/pgSQL)
-- No room may exceed capacity. One ACTIVE allocation per student.
-- ENDED allocations are history and do not occupy beds.
-- =====================================================================

DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path TO q5;

-- ---------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL DEFAULT CURRENT_DATE,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_status_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)),
    CONSTRAINT chk_release_after_allocation CHECK (released_on IS NULL OR released_on >= allocated_on)
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds     INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),   -- will be FULL
    ('R102', 3),   -- will be PARTLY occupied
    ('R103', 2);   -- will be EMPTY (only ENDED history)

INSERT INTO students (student_number, full_name) VALUES
    ('202001698', 'Mapalo Chileshe'),
    ('202001700', 'Mwila Banda'),
    ('202001701', 'Natasha Phiri'),
    ('202001702', 'Chanda Mulenga'),
    ('202001703', 'Bwalya Tembo');
-- Allocations are loaded after (c) and (d).

-- ---------------------------------------------------------------------
-- (b) Function [6 marks]
-- Only ACTIVE allocations reduce availability.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure [8 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    -- Lock the room row so two allocations cannot take the last bed together
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, COALESCE(p_allocated_on, CURRENT_DATE), NULL, 'ACTIVE');
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger [8 marks]
-- Enforces the same two rules for direct SQL INSERT/UPDATE. The row
-- being updated is excluded from both counts
-- (allocation_id <> NEW.allocation_id). In a BEFORE INSERT trigger the
-- SERIAL default is already assigned, so the comparison is safe.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_others   INTEGER;
BEGIN
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;   -- ENDED rows never occupy a bed
    END IF;

    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = NEW.student_id
                 AND status = 'ACTIVE'
                 AND allocation_id <> NEW.allocation_id) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;

    SELECT COUNT(*) INTO v_others
    FROM allocations
    WHERE room_id = NEW.room_id
      AND status = 'ACTIVE'
      AND allocation_id <> NEW.allocation_id;

    IF v_others >= v_capacity THEN
        RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- ---------------------------------------------------------------------
-- (a) continued: allocations showing full, partly occupied and empty rooms
-- ---------------------------------------------------------------------
CALL pr_allocate_room(1, 1, DATE '2026-08-01');   -- R101
CALL pr_allocate_room(2, 1, DATE '2026-08-01');   -- R101 now FULL (2/2)
CALL pr_allocate_room(3, 2, DATE '2026-08-02');   -- R102 partly (1/3)
CALL pr_allocate_room(4, 3, DATE '2026-08-02');   -- R103, then ended below
UPDATE allocations SET status = 'ENDED', released_on = DATE '2026-10-31'
WHERE student_id = 4 AND room_id = 3;             -- R103 back to EMPTY (history kept)

-- Tests for (b)
SELECT fn_free_beds(1) AS r101, fn_free_beds(2) AS r102, fn_free_beds(3) AS r103;  -- 0 | 2 | 2
-- SELECT fn_free_beds(99); -- ERROR: Unknown room_id

-- Tests for (c)
-- CALL pr_allocate_room(5, 1); -- ERROR: Room 1 is full
-- CALL pr_allocate_room(1, 2); -- ERROR: already has an ACTIVE allocation
-- CALL pr_allocate_room(99, 2); -- ERROR: Unknown student_id

-- Tests for (d): direct SQL is checked too
-- INSERT INTO allocations (student_id, room_id) VALUES (5, 1); -- ERROR: room full
-- UPDATE allocations SET room_id = 1 WHERE student_id = 3; -- ERROR: room full
UPDATE allocations SET allocated_on = DATE '2026-08-01' WHERE student_id = 1;  -- own row excluded: OK
SELECT * FROM allocations ORDER BY allocation_id;

-- ---------------------------------------------------------------------
-- (e) View [5 marks]
-- LEFT JOIN with the ACTIVE filter in the ON clause keeps rooms that
-- have no allocations (or only ENDED ones).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id
      AND a.status  = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_number;
-- R101 | 2 | 2 | 0 R102 | 3 | 1 | 2 R103 | 2 | 0 | 2

-- ---------------------------------------------------------------------
-- (f) Index [5 marks]
-- Partial index on room_id for ACTIVE rows only. Occupancy checks always
-- ask "ACTIVE allocations in room X"; ENDED history grows every term but
-- is left out, so the index stays small and matches the query exactly.
-- ---------------------------------------------------------------------
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = off;   -- demo only: tiny table would otherwise use Seq Scan
EXPLAIN ANALYZE
SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;
-- Plan: Index Scan using idx_allocations_active_room on allocations
-- Index Cond: (room_id = 1)

-- ---------------------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- One row per (snapshot_date, room_id); ON CONFLICT replaces on rerun.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();   -- rerun replaces, still 3 rows for today
SELECT * FROM occupancy_snapshot ORDER BY room_id;

-- Schedule daily at 23:55 (requires pg_cron)
ALTER PROCEDURE q5.pr_refresh_occupancy() SET search_path = q5;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q5_refresh_occupancy',
    '55 23 * * *',
    $$CALL q5.pr_refresh_occupancy()$$
);
