-- =============================================================================
-- 05_data_quality_audit.sql  ·  Level 2 — Intermediate
--
-- Before any KPI goes to management: what is in the data, what is missing,
-- and which gaps are real problems versus known limits of the source systems.
--
-- Skills shown
--   * completeness matrix with conditional aggregation (pivot without PIVOT)
--   * anti-joins (LEFT JOIN ... IS NULL, NOT EXISTS) for orphans
--   * telling "no sensor at all" apart from "sensor stopped logging"
--   * reconciliation between two systems (QC lots vs. production output)
--   * a one-screen scorecard built with UNION ALL
--
-- Every check returns the problem rows, so an empty result means "clean".
-- =============================================================================

USE melt_shop;

-- ── 1. Which columns are filled, year by year ────────────────────────────────
-- The first question about any history. It answers most "why is this chart
-- empty before 2024?" questions before anyone asks them.
SELECT
    YEAR(end_ts)                                              AS year,
    COUNT(*)                                                  AS melts,
    ROUND(100 * AVG(charge_kg        IS NOT NULL), 1)         AS charge_pct,
    ROUND(100 * AVG(gas_nm3          IS NOT NULL), 1)         AS gas_pct,
    ROUND(100 * AVG(electricity_kwh  IS NOT NULL), 1)         AS electricity_pct,
    ROUND(100 * AVG(material_cost_per_kg IS NOT NULL), 1)     AS cost_pct,
    -- oxygen only makes sense on furnaces that were fired with oxygen
    SUM(oxygen_nm3 IS NOT NULL)                               AS melts_on_oxygen
FROM melts
GROUP BY YEAR(end_ts)
ORDER BY year;
-- Reading: charge was not weighed on most orders before 2021, energy and costs
-- are recorded from 2024. These are limits of the source, not errors — but
-- every KPI that uses those columns has to say so.


-- ── 2. Control-system coverage: furnace x year ──────────────────────────────
-- A pivot table the long way: one SUM(CASE ...) per year. The cell text keeps
-- three different situations apart, which a single percentage would merge:
--   'no SCADA'  the furnace is not connected at all — nothing to recover
--   '0 / n'     connected, but nothing logged — a gap worth asking about
--   'k / n'     partial
WITH per_year AS (
    SELECT m.furnace_code,
           YEAR(m.end_ts)            AS yr,
           COUNT(*)                  AS melts,
           COUNT(r.melt_id)          AS with_scada
    FROM melts m
    LEFT JOIN furnace_regime r ON r.melt_id = m.melt_id
    GROUP BY m.furnace_code, YEAR(m.end_ts)
),
cells AS (
    SELECT p.furnace_code, p.yr,
           CASE WHEN f.has_scada = 0 THEN 'no SCADA'
                ELSE CONCAT(p.with_scada, ' / ', p.melts) END AS cell
    FROM per_year p
    JOIN furnaces f ON f.furnace_code = p.furnace_code
)
SELECT furnace_code,
       MAX(CASE WHEN yr = 2020 THEN cell END) AS `2020`,
       MAX(CASE WHEN yr = 2021 THEN cell END) AS `2021`,
       MAX(CASE WHEN yr = 2022 THEN cell END) AS `2022`,
       MAX(CASE WHEN yr = 2023 THEN cell END) AS `2023`,
       MAX(CASE WHEN yr = 2024 THEN cell END) AS `2024`,
       MAX(CASE WHEN yr = 2025 THEN cell END) AS `2025`,
       MAX(CASE WHEN yr = 2026 THEN cell END) AS `2026`
FROM cells
GROUP BY furnace_code
ORDER BY furnace_code;


-- ── 3. Where exactly is the logging gap? ────────────────────────────────────
-- Months in which a connected furnace produced but the control system wrote
-- nothing. A run of such months is a gap to report to the SCADA owner; a
-- single month is usually just a short campaign.
SELECT m.furnace_code,
       DATE_FORMAT(m.end_ts, '%Y-%m')   AS month,
       COUNT(*)                         AS melts_without_scada
FROM melts m
JOIN furnaces f ON f.furnace_code = m.furnace_code AND f.has_scada = 1
WHERE NOT EXISTS (SELECT 1 FROM furnace_regime r WHERE r.melt_id = m.melt_id)
GROUP BY m.furnace_code, DATE_FORMAT(m.end_ts, '%Y-%m')
HAVING COUNT(*) >= 2
ORDER BY m.furnace_code, month;


-- ── 4. QC lots that belong to no known melt ─────────────────────────────────
-- The QC system is loaded separately and has no foreign key to melts on
-- purpose (see 01_schema.sql). This is where its orphans show up.
SELECT l.melt_id                           AS unknown_order,
       COUNT(*)                            AS lots,
       ROUND(SUM(l.qty_kg))                AS kg,
       MIN(l.decided_at)                   AS first_decision
FROM quality_lots l
LEFT JOIN melts m ON m.melt_id = l.melt_id
WHERE m.melt_id IS NULL
GROUP BY l.melt_id
ORDER BY first_decision;


-- ── 5. Melts that never got a QC decision ───────────────────────────────────
SELECT m.melt_id, m.furnace_code, m.product_code, m.end_ts,
       ROUND(m.output_kg) AS output_kg
FROM melts m
WHERE NOT EXISTS (SELECT 1 FROM quality_lots l WHERE l.melt_id = m.melt_id)
ORDER BY m.end_ts;


-- ── 6. Reconciliation: does QC see the same tonnage production reports? ─────
-- Lots are weighed separately from the production order. A difference over
-- 2 % means lots were booked to the wrong order or are missing.
SELECT m.melt_id,
       ROUND(m.output_kg)                                   AS production_kg,
       ROUND(q.lots_kg)                                     AS qc_kg,
       ROUND((q.lots_kg / m.output_kg - 1) * 100, 2)        AS diff_pct
FROM melts m
JOIN (SELECT melt_id, SUM(qty_kg) AS lots_kg
      FROM quality_lots GROUP BY melt_id) q ON q.melt_id = m.melt_id
WHERE ABS(q.lots_kg / m.output_kg - 1) > 0.02
ORDER BY ABS(diff_pct) DESC;
-- Expected on the seed: no rows.


-- ── 7. Two melts on one furnace at the same time ────────────────────────────
-- A self-join on overlapping intervals. Impossible physically, so any hit is
-- a data-entry error (wrong furnace or wrong timestamps).
SELECT a.furnace_code, a.melt_id AS melt_a, b.melt_id AS melt_b,
       a.start_ts AS a_start, a.end_ts AS a_end, b.start_ts AS b_start
FROM melts a
JOIN melts b
  ON  b.furnace_code = a.furnace_code
  AND b.melt_id      > a.melt_id
  AND b.start_ts     < a.end_ts
  AND b.end_ts       > a.start_ts
ORDER BY a.furnace_code, a.start_ts;
-- Expected on the seed: no rows.


-- ── 8. Scorecard ────────────────────────────────────────────────────────────
-- One screen for the weekly data review. Checks that should be zero are
-- marked, so the reader does not have to know which ones are "normal".
SELECT 'melts in total'                         AS check_name, COUNT(*) AS n, 'info' AS expect FROM melts
UNION ALL
SELECT 'charge not weighed',                    SUM(charge_kg IS NULL),        'known limit before 2021' FROM melts
UNION ALL
SELECT 'output larger than charge',             SUM(output_kg > charge_kg),    'resolved in level 3, file 06' FROM melts
UNION ALL
SELECT 'melts without QC decision',             COUNT(*), 'should be ~0'
FROM melts m WHERE NOT EXISTS (SELECT 1 FROM quality_lots l WHERE l.melt_id = m.melt_id)
UNION ALL
SELECT 'QC lots of unknown orders',             COUNT(*), 'should be 0'
FROM quality_lots l WHERE NOT EXISTS (SELECT 1 FROM melts m WHERE m.melt_id = l.melt_id)
UNION ALL
SELECT 'SCADA furnace, melt without SCADA',     COUNT(*), 'gap to report'
FROM melts m JOIN furnaces f ON f.furnace_code = m.furnace_code AND f.has_scada = 1
WHERE NOT EXISTS (SELECT 1 FROM furnace_regime r WHERE r.melt_id = m.melt_id)
UNION ALL
SELECT 'melts on furnaces without SCADA',       COUNT(*), 'known limit'
FROM melts m JOIN furnaces f ON f.furnace_code = m.furnace_code AND f.has_scada = 0;
