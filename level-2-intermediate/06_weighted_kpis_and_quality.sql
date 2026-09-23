-- =============================================================================
-- 06_weighted_kpis_and_quality.sql  ·  Level 2 — Intermediate
--
-- The KPI set of the melting shop, computed so that it survives scrutiny,
-- plus the quality breakdown and the cost of non-quality.
--
-- Skills shown
--   * weighted ratios: sum over sum, over the SAME rows in both parts
--   * CTEs to keep each step readable
--   * pivot of decision codes with conditional aggregation
--   * reading a trend correctly when a business rule changed mid-series
--   * turning quality tonnage into money with explicit assumptions
-- =============================================================================

USE melt_shop;

-- ── 1. A bug worth showing: numerator and denominator over different rows ───
-- Loss = 1 - output / charge. In 2020 most charges were not weighed (NULL).
-- SUM(charge_kg) silently skips those rows, SUM(output_kg) does not — so the
-- "loss" divides the output of ALL melts by the charge of a quarter of them.
SELECT
    YEAR(end_ts)                                                    AS year,
    ROUND((1 - SUM(output_kg) / SUM(charge_kg)) * 100, 2)           AS loss_pct_WRONG,
    ROUND((1 - SUM(CASE WHEN charge_kg IS NOT NULL THEN output_kg END)
             / SUM(charge_kg)) * 100, 2)                            AS loss_pct_right,
    SUM(charge_kg IS NOT NULL)                                      AS melts_with_charge,
    COUNT(*)                                                        AS melts
FROM melts
GROUP BY YEAR(end_ts)
ORDER BY year;
-- 2020 comes out at minus several hundred percent with the wrong formula.
-- From 2022 on both agree, because every charge is weighed.


-- ── 2. KPI set per furnace and year ─────────────────────────────────────────
-- Every ratio is a ratio of sums, and each numerator is restricted to the
-- rows its denominator can see.
WITH base AS (
    SELECT
        furnace_code,
        YEAR(end_ts)                                              AS yr,
        COUNT(*)                                                  AS melts,
        SUM(output_kg)                                            AS out_kg,
        SUM(hours)                                                AS hrs,
        SUM(CASE WHEN charge_kg IS NOT NULL THEN output_kg END)   AS out_with_charge,
        SUM(charge_kg)                                            AS charge,
        SUM(CASE WHEN gas_nm3 IS NOT NULL THEN output_kg END)     AS out_with_gas,
        SUM(gas_nm3)                                              AS gas,
        AVG(loss_pct)                                             AS loss_simple_avg
    FROM melts
    GROUP BY furnace_code, YEAR(end_ts)
)
SELECT
    furnace_code,
    yr                                                            AS year,
    melts,
    ROUND(out_kg / 1000, 1)                                       AS tonnes,
    ROUND(out_kg / hrs)                                           AS kg_per_h,
    ROUND(gas / (out_with_gas / 1000), 1)                         AS gas_nm3_per_t,
    ROUND((1 - out_with_charge / charge) * 100, 2)                AS loss_pct,
    ROUND(loss_simple_avg, 2)                                     AS loss_pct_simple_avg
FROM base
ORDER BY furnace_code, year;


-- ── 3. Quality: tonnage by decision code and year ───────────────────────────
-- MySQL has no PIVOT, so one SUM(CASE ...) per code. Shares are shares of
-- tonnage, not of lot count: a 10-tonne lot and a 1-tonne lot are not equal.
WITH lots AS (
    SELECT YEAR(m.end_ts) AS yr, l.decision_code, l.qty_kg
    FROM quality_lots l
    JOIN melts m ON m.melt_id = l.melt_id          -- orphans (file 05) drop out here
)
SELECT
    yr                                                                         AS year,
    ROUND(SUM(qty_kg) / 1000)                                                  AS tonnes_decided,
    ROUND(100 * SUM(CASE WHEN decision_code = 'OK'       THEN qty_kg END) / SUM(qty_kg), 2) AS ok_pct,
    ROUND(100 * SUM(CASE WHEN decision_code = 'OK-MINOR' THEN qty_kg END) / SUM(qty_kg), 2) AS minor_pct,
    ROUND(100 * SUM(CASE WHEN decision_code = 'OK-MAJOR' THEN qty_kg END) / SUM(qty_kg), 2) AS major_pct,
    ROUND(100 * SUM(CASE WHEN decision_code = 'REMELT'   THEN qty_kg END) / SUM(qty_kg), 2) AS remelt_pct,
    ROUND(100 * SUM(CASE WHEN decision_code = 'REJECT'   THEN qty_kg END) / SUM(qty_kg), 2) AS reject_pct,
    CASE WHEN yr < 2024 THEN 'old rule' ELSE 'new rule' END                    AS remelt_rule
FROM lots
GROUP BY yr
ORDER BY yr;
-- Careful with the REMELT column: from 2024 small re-melt blends are no longer
-- coded as REMELT but released as OK-MAJOR. The drop from about 5 % to about
-- 2 % is a change of rule, not of the process. Compare within the old or
-- within the new period, never across the line. (A chart of this must carry
-- that line.)


-- ── 4. The same by category, which IS comparable across the rule change ─────
-- "Problem material" = REMELT + REJECT under the old rule, but under the new
-- rule part of it moved into OK-MAJOR. The rejected share alone is untouched
-- by the change and is the honest long-term indicator.
SELECT
    YEAR(m.end_ts)                                                              AS year,
    ROUND(100 * SUM(CASE WHEN d.category = 'conforming' THEN l.qty_kg END) / SUM(l.qty_kg), 2) AS conforming_pct,
    ROUND(100 * SUM(CASE WHEN d.category = 'remelt'     THEN l.qty_kg END) / SUM(l.qty_kg), 2) AS remelt_pct,
    ROUND(100 * SUM(CASE WHEN d.category = 'rejected'   THEN l.qty_kg END) / SUM(l.qty_kg), 2) AS rejected_pct
FROM quality_lots l
JOIN melts m          ON m.melt_id = l.melt_id
JOIN decision_codes d ON d.decision_code = l.decision_code
GROUP BY YEAR(m.end_ts)
ORDER BY year;


-- ── 5. Cost of non-quality, per year ────────────────────────────────────────
-- Costs exist from 2024 only, so the query is limited to melts that have them.
-- Assumptions, stated because the number depends on them:
--   REJECT  material and processing are both lost      -> kg x (material + conversion)
--   REMELT  material goes back into a later melt,
--           the processing is paid a second time         -> kg x conversion
-- If rejected frit is sold at a discount instead of scrapped, the true loss is
-- smaller; if a re-melt blend lowers the yield of the next melt, it is larger.
WITH priced AS (
    SELECT m.melt_id, YEAR(m.end_ts) AS yr, m.output_kg,
           m.material_cost_per_kg AS mat, m.conversion_cost_per_kg AS conv
    FROM melts m
    WHERE m.material_cost_per_kg IS NOT NULL
      AND m.conversion_cost_per_kg IS NOT NULL
),
per_melt AS (
    SELECT p.yr, p.melt_id, p.output_kg,
           SUM(CASE WHEN l.decision_code = 'REJECT' THEN l.qty_kg * (p.mat + p.conv) ELSE 0 END) AS reject_cost,
           SUM(CASE WHEN l.decision_code = 'REMELT' THEN l.qty_kg * p.conv            ELSE 0 END) AS remelt_cost
    FROM priced p
    LEFT JOIN quality_lots l ON l.melt_id = p.melt_id
    GROUP BY p.yr, p.melt_id, p.output_kg
)
SELECT
    yr                                                          AS year,
    COUNT(*)                                                    AS priced_melts,
    ROUND(SUM(reject_cost) / 1000, 1)                           AS reject_cost_k,
    ROUND(SUM(remelt_cost) / 1000, 1)                           AS remelt_cost_k,
    ROUND((SUM(reject_cost) + SUM(remelt_cost)) / 1000, 1)      AS total_k,
    ROUND((SUM(reject_cost) + SUM(remelt_cost)) / (SUM(output_kg) / 1000), 1)
                                                                AS per_tonne_produced
FROM per_melt
GROUP BY yr
ORDER BY yr;
-- per_tonne_produced divides by ALL priced tonnage, not just the bad lots: it
-- answers "what does non-quality add to every tonne we make".
