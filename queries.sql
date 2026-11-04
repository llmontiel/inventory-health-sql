-- queries.sql
-- Inventory health analytics. Each query answers an operational question an
-- inventory manager asks daily. SQLite-compatible (CTEs + window functions).

-- =========================================================================
-- Q1. Stockout rate by category
--     A stockout = a day a store-SKU had zero on-hand. In-stock rate is the
--     complement. This is the headline service-level metric.
-- =========================================================================
SELECT
    p.category,
    COUNT(*)                                              AS store_days,
    SUM(CASE WHEN i.on_hand = 0 THEN 1 ELSE 0 END)        AS stockout_days,
    ROUND(100.0 * (1 - 1.0 * SUM(CASE WHEN i.on_hand = 0 THEN 1 ELSE 0 END)
          / COUNT(*)), 2)                                 AS in_stock_rate_pct
FROM inventory_daily i
JOIN product p ON p.sku = i.sku
GROUP BY p.category
ORDER BY in_stock_rate_pct ASC;   -- worst service level first


-- =========================================================================
-- Q2. Current days-of-supply per store-SKU, using a 14-day avg sell rate
--     Days of supply = on_hand / avg daily demand. Low DOS = at risk.
--     Uses a window to average recent demand, then the latest snapshot row.
-- =========================================================================
WITH recent AS (
    SELECT
        store_id, sku, snapshot_date, on_hand,
        AVG(units_sold) OVER (
            PARTITION BY store_id, sku
            ORDER BY snapshot_date
            ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
        ) AS avg_daily_demand,
        ROW_NUMBER() OVER (
            PARTITION BY store_id, sku ORDER BY snapshot_date DESC
        ) AS rn
    FROM inventory_daily
)
SELECT
    store_id, sku,
    on_hand,
    ROUND(avg_daily_demand, 2) AS avg_daily_demand,
    -- CEILING-style guard: never report 0 days when there is stock but
    -- near-zero demand -- treat <1 demand as 1 so DOS stays meaningful.
    CASE WHEN avg_daily_demand < 1 THEN on_hand
         ELSE CAST(on_hand / avg_daily_demand AS INT) END AS days_of_supply
FROM recent
WHERE rn = 1
ORDER BY days_of_supply ASC
LIMIT 15;   -- the 15 most at-risk store-SKUs right now


-- =========================================================================
-- Q3. Replenishment watch list — items whose latest position is near or below
--     the reorder point and should be reviewed for ordering.
--     Position = on_hand + on_order. "Review window" = within 50% above ROP,
--     which catches items trending into reorder territory (a planner's daily
--     watch list), not only those already underwater.
-- =========================================================================
WITH latest AS (
    SELECT i.*,
           ROW_NUMBER() OVER (
               PARTITION BY store_id, sku ORDER BY snapshot_date DESC
           ) AS rn
    FROM inventory_daily i
)
SELECT
    l.store_id, l.sku, p.category,
    l.on_hand, l.on_order, p.reorder_point, p.case_pack,
    (l.on_hand + l.on_order)                               AS position,
    CASE WHEN (l.on_hand + l.on_order) <= p.reorder_point
         THEN 'REORDER NOW' ELSE 'WATCH' END               AS status,
    -- cases to bring the position back up to the reorder point (round up so we
    -- never order less than the shortfall implies. 0 when already above ROP
    MAX(0, CAST((p.reorder_point - (l.on_hand + l.on_order) + p.case_pack - 1)
         / p.case_pack AS INT))                            AS cases_to_order
FROM latest l
JOIN product p ON p.sku = l.sku
WHERE l.rn = 1
  AND (l.on_hand + l.on_order) <= p.reorder_point * 1.5
ORDER BY (l.on_hand + l.on_order) - p.reorder_point ASC;


-- =========================================================================
-- Q4. Stockout streaks — consecutive days a store-SKU sat at zero on-hand
--     Uses the classic "gaps and islands" pattern: subtract a row number
--     from the date to group consecutive zero-days into streaks.
-- =========================================================================
WITH zeros AS (
    SELECT store_id, sku, snapshot_date,
           julianday(snapshot_date)
             - ROW_NUMBER() OVER (
                 PARTITION BY store_id, sku ORDER BY snapshot_date
               ) AS grp
    FROM inventory_daily
    WHERE on_hand = 0
)
SELECT
    store_id, sku,
    MIN(snapshot_date) AS streak_start,
    MAX(snapshot_date) AS streak_end,
    COUNT(*)           AS streak_days
FROM zeros
GROUP BY store_id, sku, grp
HAVING COUNT(*) >= 2        -- streaks of 2+ days
ORDER BY streak_days DESC
LIMIT 10;


-- =========================================================================
-- Q5. Inventory turns (annualized) by category
--     Turns = annualized demand / avg on-hand. Higher = leaner, faster-moving.
-- =========================================================================
WITH agg AS (
    SELECT p.category,
           -- mean on-hand level across the category (avg units per store-SKU-day)
           AVG(i.on_hand)                   AS avg_on_hand_per_series,
           SUM(i.units_sold)                AS total_sold,
           COUNT(DISTINCT i.snapshot_date)  AS days,
           COUNT(DISTINCT i.store_id || i.sku) AS series
    FROM inventory_daily i
    JOIN product p ON p.sku = i.sku
    GROUP BY p.category
)
SELECT
    category,
    ROUND(avg_on_hand_per_series, 1)                         AS avg_on_hand,
    total_sold,
    -- Annual turns = annualized demand / average inventory held.
    -- Average inventory across the category = per-series avg on-hand x #series,
    -- which keeps the numerator (total demand) and denominator (total stock)
    -- on the same scale. Daily demand annualized to 365 days.
    ROUND( ((1.0 * total_sold / days) * 365.0)
           / NULLIF(avg_on_hand_per_series * series, 0), 2)  AS annual_turns
FROM agg
ORDER BY annual_turns DESC;
