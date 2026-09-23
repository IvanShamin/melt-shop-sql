-- =============================================================================
-- 03_basic_reporting.sql  ·  Level 1 — Foundations
--
-- The questions a production manager asks first, answered with plain SQL.
--
-- Skills shown
--   * SELECT / WHERE / GROUP BY / HAVING / ORDER BY / LIMIT
--   * INNER and LEFT JOIN to lookup tables
--   * date functions, CASE, ROUND, COUNT(DISTINCT)
--   * one deliberate trap: AVG of a ratio is not the ratio of the sums
--
-- Run after 01_schema.sql and data/02_seed_data.sql.
-- =============================================================================

USE melt_shop;

-- ── 1. How much did each furnace produce per year? ───────────────────────────
SELECT
    furnace_code,
    YEAR(end_ts)                         AS year,
    COUNT(*)                             AS melts,
    ROUND(SUM(output_kg) / 1000, 1)      AS tonnes,
    ROUND(SUM(hours))                    AS furnace_hours
FROM melts
GROUP BY furnace_code, YEAR(end_ts)
ORDER BY furnace_code, year;


-- ── 2. Top 10 products by tonnage, with their family ─────────────────────────
SELECT
    p.product_code,
    p.family,
    COUNT(*)                             AS melts,
    ROUND(SUM(m.output_kg) / 1000, 1)    AS tonnes,
    COUNT(DISTINCT m.furnace_code)       AS furnaces_used
FROM melts m
JOIN products p ON p.product_code = m.product_code
GROUP BY p.product_code, p.family
ORDER BY tonnes DESC
LIMIT 10;


-- ── 3. Which products are made on more than three furnaces? ──────────────────
-- HAVING filters groups, WHERE filters rows. Here we need HAVING.
SELECT
    product_code,
    COUNT(DISTINCT furnace_code)         AS furnaces_used,
    GROUP_CONCAT(DISTINCT furnace_code ORDER BY furnace_code) AS furnaces
FROM melts
GROUP BY product_code
HAVING COUNT(DISTINCT furnace_code) > 3
ORDER BY furnaces_used DESC, product_code;


-- ── 4. Melt size classes ─────────────────────────────────────────────────────
SELECT
    CASE
        WHEN output_kg <  10000 THEN '1: under 10 t'
        WHEN output_kg <  40000 THEN '2: 10-40 t'
        WHEN output_kg <  70000 THEN '3: 40-70 t'
        ELSE                         '4: 70 t and more'
    END                                  AS size_class,
    COUNT(*)                             AS melts,
    ROUND(SUM(output_kg) / SUM(hours))   AS kg_per_hour
FROM melts
GROUP BY size_class
ORDER BY size_class;


-- ── 5. Furnaces that never produced anything in the data ─────────────────────
-- LEFT JOIN + IS NULL: the classic "find the missing" pattern.
SELECT f.furnace_code, f.furnace_type
FROM furnaces f
LEFT JOIN melts m ON m.furnace_code = f.furnace_code
WHERE m.melt_id IS NULL;
-- Expected: no rows. Every furnace in the seed has production.


-- ── 6. The trap: average of a ratio vs. ratio of sums ────────────────────────
-- Throughput (kg/h) of one melt is output / hours. To get the throughput of
-- the plant it is tempting to average those per-melt figures. That gives a
-- 5-tonne melt on a small batch furnace the same weight as an 80-tonne one on
-- a continuous furnace. The honest figure is total output over total hours.
SELECT
    COUNT(*)                                          AS melts,
    ROUND(AVG(output_kg / hours))                     AS kgh_simple_average,
    ROUND(SUM(output_kg) / SUM(hours))                AS kgh_weighted,
    ROUND((AVG(output_kg / hours) / (SUM(output_kg) / SUM(hours)) - 1) * 100, 1)
                                                      AS error_pct
FROM melts;

-- Inside one furnace the melts are alike and the error is small. It is the
-- MIX of different furnaces that makes the simple average lie — which is why
-- the plant-level number above is off and these are nearly right.
SELECT
    furnace_code,
    COUNT(*)                                          AS melts,
    ROUND(AVG(output_kg / hours))                     AS kgh_simple_average,
    ROUND(SUM(output_kg) / SUM(hours))                AS kgh_weighted
FROM melts
GROUP BY furnace_code
ORDER BY furnace_code;
-- Level 2 (file 05) builds the full weighted KPI set on this idea.


-- ── 7. Last month on record, one line per furnace ────────────────────────────
SELECT
    furnace_code,
    COUNT(*)                                         AS melts,
    ROUND(SUM(output_kg) / 1000, 1)                  AS tonnes,
    DATE_FORMAT(MIN(end_ts), '%d.%m. %H:%i')         AS first_end,
    DATE_FORMAT(MAX(end_ts), '%d.%m. %H:%i')         AS last_end
FROM melts
WHERE end_ts >= (SELECT DATE_FORMAT(MAX(end_ts), '%Y-%m-01') FROM melts)
GROUP BY furnace_code
ORDER BY furnace_code;
