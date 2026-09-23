-- =============================================================================
-- 09_window_analytics.sql  ·  Level 3 — Advanced
--
-- Window functions for the questions a production card has to answer:
-- how does this product usually run, how did the last ten orders run, and is
-- this one melt unusual — compared with the right reference group.
--
-- Skills shown
--   * ROW_NUMBER() for "last N per group"
--   * AVG / STDDEV_SAMP / COUNT as window aggregates for z-scores
--   * a fallback reference group when the first one is too small
--   * a WEIGHTED moving ratio with a ROWS frame (not an average of ratios)
--   * DENSE_RANK and NTILE
-- =============================================================================

USE melt_shop;

-- ── 1. Norm vs. the last 10 orders, per product and furnace ────────────────
-- The norm is every order of the product on that furnace (weighted: sum over
-- sum). The last 10 show whether it is drifting. Per product AND furnace on
-- purpose: the same product runs at ~150 kg/h on a small batch furnace and at
-- ~500 on a continuous one, so a product-only norm would mostly measure where
-- the last orders happened to run.
-- The sign alone says nothing — for throughput higher is better, for gas lower
-- is better — so the verdict columns translate the difference, and anything
-- within 2 % of the norm is called "same": ten melts are not enough to see
-- smaller drifts through the noise.
WITH ranked AS (
    SELECT m.*,
           ROW_NUMBER() OVER (PARTITION BY product_code, furnace_code
                              ORDER BY end_ts DESC)                 AS recency,
           COUNT(*)     OVER (PARTITION BY product_code, furnace_code) AS orders
    FROM melts m
),
agg AS (
    SELECT
        product_code, furnace_code,
        MAX(orders)                                                          AS orders,
        SUM(output_kg) / SUM(hours)                                          AS kgh_norm,
        SUM(CASE WHEN recency <= 10 THEN output_kg END)
          / SUM(CASE WHEN recency <= 10 THEN hours END)                      AS kgh_last10,
        SUM(gas_nm3) / (SUM(CASE WHEN gas_nm3 IS NOT NULL THEN output_kg END) / 1000) AS gas_norm,
        SUM(CASE WHEN recency <= 10 THEN gas_nm3 END)
          / (SUM(CASE WHEN recency <= 10 AND gas_nm3 IS NOT NULL THEN output_kg END) / 1000)
                                                                             AS gas_last10
    FROM ranked
    GROUP BY product_code, furnace_code
    HAVING MAX(orders) > 10          -- with 10 or fewer, "last 10" = everything
)
SELECT
    product_code,
    furnace_code,
    orders,
    ROUND(kgh_norm)                           AS kgh_norm,
    ROUND(kgh_last10 - kgh_norm, 1)           AS kgh_last10_vs_norm,
    CASE WHEN ABS(kgh_last10 / kgh_norm - 1) < 0.02 THEN 'same'
         WHEN kgh_last10 > kgh_norm THEN 'better' ELSE 'worse' END    AS kgh_verdict,
    ROUND(gas_norm, 1)                        AS gas_norm,
    ROUND(gas_last10 - gas_norm, 1)           AS gas_last10_vs_norm,
    CASE WHEN ABS(gas_last10 / gas_norm - 1) < 0.02 THEN 'same'
         WHEN gas_last10 < gas_norm THEN 'better' ELSE 'worse' END    AS gas_verdict
FROM agg
ORDER BY orders DESC
LIMIT 15;


-- ── 2. Is this melt unusual? z-score against the right group ────────────────
-- Comparing a melt with the plant average says mostly which product it was.
-- The fair reference is the same product on the same furnace; if that pair
-- has fewer than 5 weighed melts, fall back to the product on any furnace;
-- if even that is too thin, give no score rather than a misleading one.
WITH stats AS (
    SELECT
        m.melt_id, m.product_code, m.furnace_code, m.end_ts, m.loss_pct,
        AVG(m.loss_pct)         OVER pair AS pair_avg,
        STDDEV_SAMP(m.loss_pct) OVER pair AS pair_sd,
        COUNT(m.loss_pct)       OVER pair AS pair_n,
        AVG(m.loss_pct)         OVER prod AS prod_avg,
        STDDEV_SAMP(m.loss_pct) OVER prod AS prod_sd,
        COUNT(m.loss_pct)       OVER prod AS prod_n
    FROM melts m
    WINDOW pair AS (PARTITION BY m.product_code, m.furnace_code),
           prod AS (PARTITION BY m.product_code)
),
scored AS (
    SELECT s.*,
           CASE WHEN pair_n >= 5 AND pair_sd > 0 THEN (loss_pct - pair_avg) / pair_sd
                WHEN prod_n >= 5 AND prod_sd > 0 THEN (loss_pct - prod_avg) / prod_sd
           END AS z,
           CASE WHEN pair_n >= 5 AND pair_sd > 0 THEN 'product + furnace'
                WHEN prod_n >= 5 AND prod_sd > 0 THEN 'product only'
                ELSE 'too few melts' END AS reference
    FROM stats s
    WHERE s.loss_pct IS NOT NULL
)
SELECT melt_id, product_code, furnace_code, DATE(end_ts) AS ended,
       ROUND(loss_pct, 2) AS loss_pct, ROUND(z, 2) AS z, reference
FROM scored
WHERE ABS(z) >= 2.5
ORDER BY ABS(z) DESC
LIMIT 15;
-- Most of the extreme low scores are negative losses — the spill-over melts
-- from 07_campaigns_gaps_and_islands.sql, found here again independently.
-- Scoring the run-level loss from that file instead of the order-level one
-- leaves the genuinely unusual melts.

-- How often each reference was used — worth knowing before trusting the list.
SELECT reference, COUNT(*) AS melts
FROM (
    SELECT CASE WHEN COUNT(loss_pct) OVER (PARTITION BY product_code, furnace_code) >= 5
                THEN 'product + furnace'
                WHEN COUNT(loss_pct) OVER (PARTITION BY product_code) >= 5
                THEN 'product only'
                ELSE 'too few melts' END AS reference
    FROM melts
    WHERE loss_pct IS NOT NULL
) r
GROUP BY reference;


-- ── 3. Gas per tonne, moving over the last 10 melts of each furnace ─────────
-- AVG(gas / tonnes) OVER (...) would be the average of ratios again (see
-- 03_basic_reporting.sql, query 6). The right moving figure is the moving sum
-- of gas over the moving sum of tonnes, with the same frame on both.
SELECT
    furnace_code,
    melt_id,
    DATE(end_ts)                                                         AS ended,
    ROUND(gas_nm3 / (output_kg / 1000), 1)                               AS this_melt,
    ROUND(SUM(gas_nm3)           OVER w10
        / (SUM(output_kg / 1000) OVER w10), 1)                           AS moving_10_weighted,
    ROUND(AVG(gas_nm3 / (output_kg / 1000)) OVER w10, 1)                 AS moving_10_naive
FROM melts
WHERE furnace_code = 'C01' AND gas_nm3 IS NOT NULL
WINDOW w10 AS (PARTITION BY furnace_code ORDER BY end_ts
               ROWS BETWEEN 9 PRECEDING AND CURRENT ROW)
ORDER BY end_ts DESC
LIMIT 12;


-- ── 4. Ranking products by energy, inside their family ──────────────────────
-- DENSE_RANK inside each family: comparing an opaque frit with a clear one on
-- gas per tonne mostly measures the recipe, not the process.
SELECT *
FROM (
    SELECT
        p.family,
        m.product_code,
        COUNT(*)                                                    AS melts,
        ROUND(SUM(m.gas_nm3) / (SUM(m.output_kg) / 1000), 1)        AS gas_nm3_per_t,
        DENSE_RANK() OVER (PARTITION BY p.family
                           ORDER BY SUM(m.gas_nm3) / SUM(m.output_kg) DESC) AS rank_in_family
    FROM melts m
    JOIN products p ON p.product_code = m.product_code
    WHERE m.gas_nm3 IS NOT NULL
      AND m.furnace_code LIKE 'C%'                 -- continuous furnaces only
    GROUP BY p.family, m.product_code
    HAVING COUNT(*) >= 10
) r
WHERE rank_in_family <= 3
ORDER BY family, rank_in_family;


-- ── 5. Bigger melts run faster: quartiles of melt size ──────────────────────
-- NTILE splits each furnace's melts into four equal groups by size. Throughput
-- rising from Q1 to Q4 is the size effect every kg/h comparison has to allow
-- for: two furnaces melting different batch sizes are not comparable as is.
SELECT
    size_quartile,
    COUNT(*)                                    AS melts,
    ROUND(AVG(output_kg) / 1000, 1)             AS avg_tonnes,
    ROUND(SUM(output_kg) / SUM(hours))          AS kg_per_h
FROM (
    SELECT m.*,
           NTILE(4) OVER (PARTITION BY furnace_code ORDER BY output_kg) AS size_quartile
    FROM melts m
    WHERE furnace_code LIKE 'C%'
) q
GROUP BY size_quartile
ORDER BY size_quartile;
