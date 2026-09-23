-- =============================================================================
-- 08_gas_model_regression.sql  ·  Level 3 — Advanced
--
-- How much gas does a furnace burn just to stay hot, and how much to melt a
-- tonne? Fitted per furnace and year with least squares — in plain SQL.
--
--     gas = a * hours + b * tonnes          (no intercept)
--       a  standing consumption, Nm3 per furnace hour
--       b  melting consumption,  Nm3 per tonne
--
-- For two regressors without an intercept the normal equations have a
-- closed-form solution made only of sums, so GROUP BY can fit one model per
-- group in a single pass:
--
--     | Shh  Sht | |a|   |Sgh|          det = Shh*Stt - Sht^2
--     | Sht  Stt | |b| = |Sgt|          a = (Sgh*Stt - Sgt*Sht) / det
--                                       b = (Sgt*Shh - Sgh*Sht) / det
--
-- Skills shown
--   * regression from aggregate sums (normal equations)
--   * goodness of fit in a second pass, centred and uncentred R^2
--   * Pearson correlation from sums, to expose collinearity
--   * flagging models that must not be read (negative b, too few melts)
--   * a mix-adjusted before/after comparison around maintenance events
-- =============================================================================

USE melt_shop;

-- ── 1. Fit ───────────────────────────────────────────────────────────────────
DROP TABLE IF EXISTS gas_models;
CREATE TABLE gas_models AS
WITH obs AS (
    SELECT furnace_code,
           YEAR(end_ts)        AS yr,
           hours               AS h,
           output_kg / 1000    AS t,
           gas_nm3             AS g
    FROM melts
    WHERE gas_nm3 IS NOT NULL
),
sums AS (
    SELECT furnace_code, yr,
           COUNT(*) AS n,
           SUM(h*h) AS shh, SUM(t*t) AS stt, SUM(h*t) AS sht,
           SUM(g*h) AS sgh, SUM(g*t) AS sgt,
           SUM(h)   AS sh,  SUM(t)   AS st,  SUM(g)   AS sg, SUM(g*g) AS sgg
    FROM obs
    GROUP BY furnace_code, yr
)
SELECT
    furnace_code, yr, n,
    (sgh*stt - sgt*sht) / (shh*stt - sht*sht)              AS a,
    (sgt*shh - sgh*sht) / (shh*stt - sht*sht)              AS b,
    -- how strongly hours and tonnes move together: near 1 means the split
    -- between a and b is poorly determined, even when the total fits well
    (n*sht - sh*st) / SQRT((n*shh - sh*sh) * (n*stt - st*st)) AS r_hours_tonnes,
    sg / st                                                AS nm3_per_t,
    sg, sgg
FROM sums
WHERE n >= 3;


-- ── 2. Goodness of fit: needs the residuals, so a second pass ───────────────
-- R^2 for a model WITHOUT an intercept is often reported "uncentred"
-- (1 - SSE / sum(g^2)). It is always high and flatters the model. The centred
-- version (1 - SSE / sum((g - mean)^2)) is the honest one; both are shown.
DROP TABLE IF EXISTS gas_model_fit;
CREATE TABLE gas_model_fit AS
SELECT
    gm.furnace_code, gm.yr, gm.n,
    gm.a, gm.b, gm.r_hours_tonnes, gm.nm3_per_t,
    1 - SUM(POW(m.gas_nm3 - (gm.a * m.hours + gm.b * m.output_kg / 1000), 2))
          / (gm.sgg - gm.sg * gm.sg / gm.n)              AS r2_centred,
    1 - SUM(POW(m.gas_nm3 - (gm.a * m.hours + gm.b * m.output_kg / 1000), 2))
          / gm.sgg                                        AS r2_uncentred
FROM gas_models gm
JOIN melts m
  ON  m.furnace_code = gm.furnace_code
  AND YEAR(m.end_ts) = gm.yr
  AND m.gas_nm3 IS NOT NULL
GROUP BY gm.furnace_code, gm.yr, gm.n, gm.a, gm.b, gm.r_hours_tonnes,
         gm.nm3_per_t, gm.sg, gm.sgg;

SELECT
    furnace_code, yr AS year, n,
    ROUND(a, 1)                 AS a_nm3_per_h,
    ROUND(b, 1)                 AS b_nm3_per_t,
    ROUND(nm3_per_t, 1)         AS actual_nm3_per_t,
    ROUND(r2_centred, 3)        AS r2,
    ROUND(r2_uncentred, 3)      AS r2_uncentred,
    ROUND(r_hours_tonnes, 2)    AS r_hours_tonnes,
    CASE WHEN b < 0 OR a < 0 THEN 'do not read: negative coefficient'
         WHEN n < 10         THEN 'do not read: fewer than 10 melts'
         WHEN r_hours_tonnes > 0.95 THEN 'split a/b unreliable'
         ELSE '' END            AS warning
FROM gas_model_fit
ORDER BY furnace_code, yr;
-- Reading: hours and tonnes correlate at 0.9+ almost everywhere (a bigger
-- melt simply takes longer), so the TOTAL is predicted well while the split
-- into a and b is shaky — hence the warning column. Three models come out
-- negative. Two of them, C02 2021 and C05 2023, are the years in which those
-- furnaces were converted from air to oxygen: one model fitted across two
-- different regimes. The fix is to split the period at the conversion date,
-- not to trust the numbers. The third, R01 2022, is plain collinearity:
-- r = 0.99, the data cannot tell the two terms apart.


-- ── 3. What standing costs, per furnace (latest year) ──────────────────────
-- a is gas burnt whether or not anything melts, so a x price x 24 is the
-- price of one idle furnace-day. A cost of keeping hot, not a loss: the
-- furnace has to stay hot between orders.
SELECT
    f.furnace_code,
    f.yr                                             AS year,
    ROUND(f.a, 1)                                    AS a_nm3_per_h,
    ROUND(f.a * t.gas_per_nm3 * 24)                  AS idle_cost_per_day
FROM gas_model_fit f
JOIN energy_tariffs t ON t.tariff_year = f.yr
WHERE f.yr = (SELECT MAX(yr) FROM gas_model_fit)
  AND f.a > 0 AND f.b > 0 AND f.n >= 10
ORDER BY idle_cost_per_day DESC;


-- ── 4. Did the overhaul pay off? A mix-adjusted before/after ────────────────
-- Comparing gas per tonne 12 months before and after an overhaul is tempting
-- and wrong: after the overhaul the furnace may simply melt easier products.
-- So the "after" period is compared with what it WOULD have burned at the
-- "before" period's gas per tonne for each product:
--
--     expected_after = sum over products of  tonnes_after(p) * intensity_before(p)
--     change         = actual_after / expected_after - 1
--
-- Products melted in only one of the two windows cannot be compared and are
-- left out; how much of the tonnage that is, is reported next to the result.
WITH windows AS (
    SELECT e.event_id, e.furnace_code, e.event_date, e.event_type,
           m.product_code,
           CASE WHEN m.end_ts <  e.event_date THEN 'before' ELSE 'after' END AS side,
           m.output_kg, m.gas_nm3
    FROM maintenance_events e
    JOIN melts m
      ON  m.furnace_code = e.furnace_code
      AND m.gas_nm3 IS NOT NULL
      AND m.end_ts >= e.event_date - INTERVAL 12 MONTH
      AND m.end_ts <  e.event_date + INTERVAL 12 MONTH
),
per_product AS (
    SELECT event_id, product_code,
           SUM(CASE WHEN side = 'before' THEN gas_nm3   END)          AS gas_b,
           SUM(CASE WHEN side = 'before' THEN output_kg END) / 1000   AS t_b,
           SUM(CASE WHEN side = 'after'  THEN gas_nm3   END)          AS gas_a,
           SUM(CASE WHEN side = 'after'  THEN output_kg END) / 1000   AS t_a
    FROM windows
    GROUP BY event_id, product_code
)
SELECT
    e.furnace_code,
    e.event_date,
    e.event_type,
    ROUND(SUM(p.gas_b) / SUM(p.t_b), 1)                              AS raw_before_nm3_t,
    ROUND(SUM(p.gas_a) / SUM(p.t_a), 1)                              AS raw_after_nm3_t,
    ROUND(100 * (SUM(CASE WHEN p.t_b > 0 THEN p.gas_a END)
                 / SUM(CASE WHEN p.t_b > 0 THEN p.t_a * p.gas_b / p.t_b END) - 1), 1)
                                                                     AS mix_adjusted_change_pct,
    ROUND(100 * SUM(CASE WHEN p.t_b > 0 THEN p.t_a END) / SUM(p.t_a))  AS comparable_tonnage_pct
FROM maintenance_events e
JOIN per_product p ON p.event_id = e.event_id
GROUP BY e.event_id, e.furnace_code, e.event_date, e.event_type
HAVING SUM(p.t_a) > 0 AND SUM(p.t_b) > 0
ORDER BY e.event_date;
-- Reading: a negative mix-adjusted change means the furnace burns less gas
-- for the same products after the event. The conversions to oxygen show the
-- largest step (about -25 %), overhauls a few percent. Look at the C01
-- overhaul of April 2023: the raw figures say gas per tonne went UP, the
-- mix-adjusted change says it went down — after the overhaul the furnace was
-- given harder products. Where comparable_tonnage_pct is low, too few
-- products overlap and the figure should not be quoted.
