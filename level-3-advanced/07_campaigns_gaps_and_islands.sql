-- =============================================================================
-- 07_campaigns_gaps_and_islands.sql  ·  Level 3 — Advanced
--
-- The problem. Some melts produce MORE frit than was charged — physically
-- impossible. They are not typos: the same product is often melted as a run
-- of consecutive orders on one furnace, and a few bags spill over from one
-- order to the next in the booking. One order looks too good, the next too
-- bad. Checked order by order, both are wrong; checked as a run, both are
-- right.
--
-- The fix is a classic gaps-and-islands problem: group consecutive melts of
-- the same product on the same furnace into runs ("campaigns"), then compute
-- the loss per run.
--
-- Skills shown
--   * LAG() to compare each row with the previous one in its partition
--   * running SUM() of a "new group starts here" flag to number the islands
--   * a named WINDOW clause
--   * recomputing a metric at group level and pushing it back to rows
--   * proving the fix: totals unchanged, impossible rows gone
-- =============================================================================

USE melt_shop;

-- A run ends when the product changes, or when the furnace was idle for more
-- than 30 days — after a long stop the next order is a new start, even with
-- the same product.
SET @max_gap_days = 30;

-- ── 1. Number the runs ───────────────────────────────────────────────────────
-- Materialised once as a derived table, because the next steps read it
-- several times. (A TEMPORARY table would not do: MySQL cannot open the same
-- temporary table twice in one query, and step 3 needs exactly that.)
DROP TABLE IF EXISTS melt_run_loss;
DROP TABLE IF EXISTS melt_runs;
CREATE TABLE melt_runs AS
WITH ordered AS (
    SELECT
        m.melt_id, m.furnace_code, m.product_code, m.start_ts, m.end_ts,
        m.charge_kg, m.output_kg, m.loss_pct,
        LAG(m.product_code) OVER w AS prev_product,
        LAG(m.end_ts)       OVER w AS prev_end
    FROM melts m
    WINDOW w AS (PARTITION BY m.furnace_code ORDER BY m.start_ts, m.melt_id)
),
flagged AS (
    SELECT o.*,
           CASE WHEN o.prev_product = o.product_code
                 AND o.start_ts <= o.prev_end + INTERVAL @max_gap_days DAY
                THEN 0 ELSE 1 END AS starts_new_run
    FROM ordered o
)
SELECT
    f.*,
    -- running total of "starts a new run" = run number within the furnace
    SUM(f.starts_new_run) OVER (PARTITION BY f.furnace_code
                                ORDER BY f.start_ts, f.melt_id
                                ROWS UNBOUNDED PRECEDING) AS run_no
FROM flagged f;

-- a readable, globally unique run id such as C03-0042
ALTER TABLE melt_runs ADD COLUMN run_id VARCHAR(16);
UPDATE melt_runs SET run_id = CONCAT(furnace_code, '-', LPAD(run_no, 4, '0'));


-- ── 2. What the runs look like ───────────────────────────────────────────────
SELECT
    melts_in_run,
    COUNT(*)                             AS runs,
    SUM(melts_in_run)                    AS melts,
    ROUND(100 * SUM(melts_in_run) / (SELECT COUNT(*) FROM melts), 1) AS pct_of_melts
FROM (SELECT run_id, COUNT(*) AS melts_in_run FROM melt_runs GROUP BY run_id) r
GROUP BY melts_in_run
ORDER BY melts_in_run;


-- ── 3. Loss per run, pushed back to every melt of the run ───────────────────
-- Only melts with a weighed charge take part, on both sides of the ratio.
-- A window aggregate does the "group and push back" in one pass.
CREATE TABLE melt_run_loss AS
SELECT
    r.*,
    COUNT(*) OVER run                                                AS melts_in_run,
    (1 - SUM(CASE WHEN r.charge_kg IS NOT NULL THEN r.output_kg END) OVER run
         / SUM(r.charge_kg) OVER run) * 100                          AS run_loss_pct
FROM melt_runs r
WINDOW run AS (PARTITION BY r.run_id);

-- The spill-over cases, side by side: order-level loss is negative, the run
-- it belongs to is perfectly normal.
SELECT run_id, melt_id, product_code, DATE(end_ts) AS ended,
       ROUND(loss_pct, 2)     AS order_loss_pct,
       ROUND(run_loss_pct, 2) AS run_loss_pct,
       melts_in_run
FROM melt_run_loss
WHERE run_id IN (SELECT run_id FROM melt_run_loss WHERE loss_pct < 0)
ORDER BY run_id, start_ts
LIMIT 24;


-- ── 4. Proof ─────────────────────────────────────────────────────────────────
-- (a) Nothing was added or removed: the plant-level loss is identical,
--     because the run level only re-draws the lines between orders.
-- (b) The impossible values are gone.
SELECT
    ROUND((1 - SUM(CASE WHEN charge_kg IS NOT NULL THEN output_kg END)
             / SUM(charge_kg)) * 100, 3)                    AS plant_loss_pct,
    SUM(loss_pct < 0)                                       AS negative_orders,
    SUM(run_loss_pct < 0)                                   AS negative_runs_rows,
    SUM(melts_in_run > 1)                                   AS melts_in_multi_runs
FROM melt_run_loss;
-- A run can still end up negative if EVERY order in it received spilled
-- material and none gave any away — rare, and then worth a closer look.


-- ── 5. Changeovers: how often does each furnace switch product? ─────────────
-- The same run numbering answers an operations question for free.
SELECT
    furnace_code,
    YEAR(start_ts)                                  AS year,
    COUNT(DISTINCT run_id)                          AS runs,
    COUNT(*)                                        AS melts,
    ROUND(COUNT(*) / COUNT(DISTINCT run_id), 2)     AS melts_per_run
FROM melt_runs
GROUP BY furnace_code, YEAR(start_ts)
ORDER BY furnace_code, year;
