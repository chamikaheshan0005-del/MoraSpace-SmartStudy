-- =====================================================================
-- MoraSpace SmartStudy - Simple Editable Database (PostgreSQL)
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- 1. TABLES (Only 2 tables: study_areas & occupancy_snapshots)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS study_areas (
    id               SERIAL PRIMARY KEY,
    slug             VARCHAR(50)  NOT NULL UNIQUE, -- Short ID used by frontend/backend ('apaya', 'centra')
    name             VARCHAR(120) NOT NULL UNIQUE, -- Display name ('Apaya Area', 'Centra Area')
    capacity         INTEGER      NOT NULL DEFAULT 50 CHECK (capacity > 0),
    wifi_available   BOOLEAN      NOT NULL DEFAULT TRUE,
    is_active        BOOLEAN      NOT NULL DEFAULT TRUE --✅ mchn methn api krnne table create krn ek methn table ekyi phl table ekyi mewge thm api data store krnne
);

CREATE TABLE IF NOT EXISTS occupancy_snapshots ( --✅methnn thm api sensor wlin gnn data store wenne api windi 3n 3t wge repeat wenn hdmu ned
    id               BIGSERIAL PRIMARY KEY,
    study_area_id    INTEGER     NOT NULL REFERENCES study_areas(id) ON DELETE CASCADE, --✅on delete escade kiyn eken api me study area ek ayin kroth eke records tikth ayin wenw
    student_count    INTEGER     NOT NULL CHECK (student_count >= 0),
    recorded_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_snapshots_area_time 
ON occupancy_snapshots (study_area_id, recorded_at DESC); 

-- ---------------------------------------------------------------------
-- 
-- ---------------------------------------------------------------------

INSERT INTO study_areas (slug, name, capacity, wifi_available) --✅methn thm api data store krnne table wlt
VALUES
   
    ('apaya',  'Apaya Area',  60, TRUE),--✅methnin thm apit capacity wens krnn aluth study areas add krnn hdnn puluwn
    ('centra', 'Centra Area', 50, FALSE)
ON CONFLICT (slug) DO UPDATE--✅ methn on conflict kiyl thiyen eken dent existing database ek update krnw
SET name             = EXCLUDED.name,
    capacity         = EXCLUDED.capacity,
    wifi_available   = EXCLUDED.wifi_available;
    
-- ---------------------------------------------------------------------
-- 3. VIEW: CURRENT OCCUPANCY (Read by FastAPI /api/study-areas)--✅methnt thm api sambnd wenne backend eken
-- ---------------------------------------------------------------------

DROP VIEW IF EXISTS v_current_occupancy;
CREATE VIEW v_current_occupancy AS
SELECT--✅Your backend can use this view to retrieve occupancy information without repeating the same calculation in every API query.
    a.id AS study_area_id,
    a.name,
    a.slug,
    a.wifi_available,
    a.capacity,
    COALESCE(s.student_count, 0) AS student_count,
    s.recorded_at,
    ROUND((COALESCE(s.student_count, 0)::NUMERIC / a.capacity) * 100, 1) AS occupancy_percent,
    GREATEST(a.capacity - COALESCE(s.student_count, 0), 0) AS seats_available,
    -- ✏️ EDIT HERE: Change percentage thresholds for Quiet / Moderate / Busy / Full
    CASE
        WHEN (COALESCE(s.student_count, 0)::NUMERIC / a.capacity) * 100 < 40 THEN 'Quiet'
        WHEN (COALESCE(s.student_count, 0)::NUMERIC / a.capacity) * 100 < 70 THEN 'Moderate'
        WHEN (COALESCE(s.student_count, 0)::NUMERIC / a.capacity) * 100 < 90 THEN 'Busy'
        ELSE 'Full'
    END AS level
FROM study_areas a
LEFT JOIN LATERAL (--✅mrthinin thm apit latestm snap shot ek gnn puluwn keedenek innwd kiyl
    SELECT student_count, recorded_at
    FROM occupancy_snapshots o
    WHERE o.study_area_id = a.id
    ORDER BY o.recorded_at DESC
    LIMIT 1
) s ON TRUE --✅methn me s kiynne subquerie ekk eken krnne apit latestm snapshot ek backend ekt denw

WHERE a.is_active = TRUE
ORDER BY a.id;

-- ---------------------------------------------------------------------
-- 4. FUNCTION 1: SAVE STUDENT COUNT (Called by FastAPI when data arrives)
--    Works with EITHER slug ('apaya') OR name ('Apaya Area')
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION record_occupancy(
    p_area   TEXT,
    p_count  INTEGER
) RETURNS BIGINT AS $$
DECLARE
    v_area_id INTEGER;
    v_snap_id BIGINT;
BEGIN
    SELECT id INTO v_area_id
    FROM study_areas
    WHERE (LOWER(slug) = LOWER(p_area) OR LOWER(name) = LOWER(p_area))
      AND is_active = TRUE;

    IF v_area_id IS NULL THEN
        RAISE EXCEPTION 'Study area not found: %', p_area;
    END IF;

    INSERT INTO occupancy_snapshots (study_area_id, student_count)
    VALUES (v_area_id, GREATEST(p_count, 0))
    RETURNING id INTO v_snap_id;

    RETURN v_snap_id;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- 5. FUNCTION 2: RECOMMEND BEST STUDY TIMES (Called by FastAPI)
--    Finds the quietest hours directly from occupancy_snapshots
-- ---------------------------------------------------------------------
--✅methn thm podi case ekk thiyenne api ek ek study area eke wed krnn hod welw pennanw nm apit backend eken request krl adl welwl arn frontend eke display krnn wenw
DROP FUNCTION IF EXISTS recommend_study_times(TEXT, INTEGER, INTEGER);
CREATE OR REPLACE FUNCTION recommend_study_times(
    p_area_name   TEXT    DEFAULT NULL, -- NULL = all areas
    p_day_of_week INTEGER DEFAULT NULL, -- Ignored if not enough data; uses overall quietest hour
    p_top         INTEGER DEFAULT 3, --❌    -- Number of best hours to return per area ✅methn apit puluwn hodm welwl thunk wge illa gnn
    p_open_hour   INTEGER DEFAULT 8,  -- First hour the study area is open (24h clock, Colombo time)
    p_close_hour  INTEGER DEFAULT 22  -- Hour the study area closes (last recommended window ends here)
) RETURNS TABLE (
    area_name       TEXT,
    time_window     TEXT,
    typical_count   NUMERIC,
    typical_percent NUMERIC,
    level           TEXT
) AS $$
DECLARE
    v_dow INTEGER := p_day_of_week;
BEGIN
    -- Ignore the weekday filter if there is no data for that weekday
    IF v_dow IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM occupancy_snapshots o
        WHERE o.recorded_at >= NOW() - INTERVAL '14 days'
          AND EXTRACT(DOW FROM o.recorded_at AT TIME ZONE 'Asia/Colombo')::INT = v_dow
    ) THEN
        v_dow := NULL;
    END IF;

    RETURN QUERY
    WITH hourly_stats AS (

        SELECT
            a.id AS area_id,
            a.name::TEXT AS nm,
            a.capacity AS cap,

            EXTRACT(
                HOUR FROM o.recorded_at AT TIME ZONE 'Asia/Colombo'
            )::INT AS hr,

            ROUND(AVG(o.student_count), 1) AS avg_cnt,

            ROUND(
                (AVG(o.student_count)::NUMERIC / a.capacity) * 100,
                1
            ) AS avg_pct

        FROM occupancy_snapshots o

        JOIN study_areas a
            ON a.id = o.study_area_id

        WHERE a.is_active = TRUE

          -- Select a specific study area when requested
          AND (
              p_area_name IS NULL
              OR LOWER(a.name) = LOWER(p_area_name)
              OR LOWER(a.slug) = LOWER(p_area_name)
          )

          -- Consider only the previous 14 days
          AND o.recorded_at >= NOW() - INTERVAL '14 days'

          -- Filter by weekday when requested
          AND (
              v_dow IS NULL
              OR EXTRACT(
                  DOW FROM o.recorded_at AT TIME ZONE 'Asia/Colombo'
              )::INT = v_dow
          )

          -- Only consider hours when the study area is open
          AND EXTRACT(
                  HOUR FROM o.recorded_at AT TIME ZONE 'Asia/Colombo'
              )::INT >= p_open_hour
          AND EXTRACT(
                  HOUR FROM o.recorded_at AT TIME ZONE 'Asia/Colombo'
              )::INT < p_close_hour

        GROUP BY
            a.id,
            a.name,
            a.capacity,
            EXTRACT(
                HOUR FROM o.recorded_at AT TIME ZONE 'Asia/Colombo'
            )::INT
    ),

    ranked AS (

        SELECT
            hs.area_id,
            hs.nm,
            hs.hr,
            hs.avg_cnt,
            hs.avg_pct,

            ROW_NUMBER() OVER (
                PARTITION BY hs.area_id
                ORDER BY hs.avg_pct ASC, hs.hr ASC
            ) AS rk

        FROM hourly_stats hs
    )

    SELECT
        r.nm,

        (
            to_char(make_timestamp(2000, 1, 1, r.hr, 0, 0), 'HH12:MI AM')
            || ' - ' ||
            to_char(
                make_timestamp(2000, 1, 1, r.hr, 0, 0) + INTERVAL '1 hour',
                'HH12:MI AM'
            )
        )::TEXT,

        r.avg_cnt,
        r.avg_pct,

        (CASE
            WHEN r.avg_pct < 40 THEN 'Quiet'
            WHEN r.avg_pct < 70 THEN 'Moderate'
            WHEN r.avg_pct < 90 THEN 'Busy'
            ELSE 'Full'
        END)::TEXT

    FROM ranked r
    WHERE r.rk <= p_top
    ORDER BY r.nm, r.rk;

END;
$$ LANGUAGE plpgsql STABLE;

COMMIT;


/* ✅mechn bn mn krl thiyenne hrid den user onn agaharuwd dwsk aw ub backend eken request ekk dunnm database eken pahugiy sathi dekk e agaharuwda dwse kohomd kattiy 
idl thiyenne kiyl blnw itpsse hodm welwl thunk reccomend krnw oni nm ek adu wedi krgnn puluwn mn ❌ lakunkin dl thiyen then default ek wens krl */
