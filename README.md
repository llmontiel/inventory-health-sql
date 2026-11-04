# Inventory Health SQL

Operational SQL analytics for retail inventory — the queries an inventory
manager runs to answer "what's at risk right now?" Stockout rates, days-of-supply,
a replenishment watch list, stockout streaks, and inventory turns, all on a
simulated daily inventory feed.

> Runs on fully synthetic data (no real or confidential information) and uses
> only Python's standard library — `sqlite3`, zero dependencies. Clone and run.

## What's inside

```
schema.sql   ->  build_db.py  ->  inventory.db  ->  queries.sql
(2 tables)      (simulates +      (SQLite DB)      (5 analytical queries)
                 loads inventory)
```

- schema.sql — `inventory_daily` (daily on-hand/sales/on-order snapshots) plus a
  `product` reference table with lead time, reorder point, and case pack.
- build_db.py — simulates a realistic order-up-to replenishment policy (with
  lead-time and review variability) across 4 stores × 6 SKUs × 120 days, so the
  health queries have genuine stockouts and reorder situations to find.
- queries.sql — five operational queries, each a distinct SQL technique.

## The queries (and the skill each shows)

| # | Question | SQL technique |
|---|---|---|
| Q1 | In-stock / stockout rate by category | Conditional aggregation |
| Q2 | Current days-of-supply per store-SKU | Rolling-window avg + `ROW_NUMBER` latest-row |
| Q3 | Replenishment watch list | Latest-snapshot filter + reorder logic |
| Q4 | Stockout streaks (consecutive zero-days) | Gaps-and-islands pattern |
| Q5 | Annualized inventory turns by category | Ratio with careful unit alignment |

## Sample verified output

```
Q1. In-stock rate by category
category   | in_stock_rate_pct
Beverage   | 97.40
Snacks     | 90.73
Candy      | 90.63
Breakfast  | 87.71

Q4. Stockout streaks (consecutive zero-days)
store_id   | sku              | streak_start | streak_end | streak_days
STORE_LAX  | SKU_CHIPS_FAMILY | 2025-02-19   | 2025-02-23 | 5

Q5. Annualized inventory turns
category   | annual_turns
Candy      | 61.1
Beverage   | 61.0
```

## Quickstart

```bash
python build_db.py            # builds inventory.db and runs all 5 queries
python build_db.py --rebuild  # drop and rebuild from scratch
```

No installs needed — `sqlite3` ships with Python. To explore interactively:

```bash
sqlite3 inventory.db
sqlite> .read queries.sql
```

## Why it's built this way

- Gaps-and-islands for streaks — detecting consecutive stockout days is a classic
  SQL problem; subtracting a row number from the date groups consecutive days
  into streaks. It's the clean, set-based way to do it without procedural loops.
- A rolling 14-day demand window for days-of-supply — demand is noisy day to day;
  averaging a trailing window gives a stable sell rate to divide on-hand by.
- Careful turns math — inventory turns are easy to get wrong by mixing per-row
  average stock with category-total flow. The query keeps numerator (demand) and
  denominator (inventory held) on the same scale so the ratio is meaningful.
- Reorder logic rounds up to whole cases — you can't order a fraction of a case,
  and under-ordering drives stockouts, so case counts always round up.

## Repo structure

```
inventory-health-sql/
├── schema.sql       # inventory_daily + product tables
├── queries.sql      # 5 operational inventory queries
├── build_db.py      # simulate + load + run (stdlib only)
└── inventory.db     # generated SQLite DB (reproducible)
```
