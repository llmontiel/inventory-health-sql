-- schema.sql
-- Inventory health analytics schema (SQLite).
-- Daily snapshot of on-hand inventory and sales per store-SKU, plus a small
-- product reference table with reorder parameters. Built to answer operational
-- "is this item healthy?" questions: stockouts, days-of-supply, reorder flags.

DROP TABLE IF EXISTS inventory_daily;
DROP TABLE IF EXISTS product;

CREATE TABLE product (
    sku             TEXT PRIMARY KEY,
    category        TEXT    NOT NULL,
    lead_time_days  INTEGER NOT NULL,   -- supplier replenishment lead time
    reorder_point   INTEGER NOT NULL,   -- units; trigger a reorder at/below this
    case_pack       INTEGER NOT NULL    -- units per case (ordering granularity)
);

CREATE TABLE inventory_daily (
    snapshot_date   TEXT    NOT NULL,   -- YYYY-MM-DD
    store_id        TEXT    NOT NULL,
    sku             TEXT    NOT NULL REFERENCES product(sku),
    on_hand         INTEGER NOT NULL,   -- units on shelf at start of day
    units_sold      INTEGER NOT NULL,   -- units sold that day
    on_order        INTEGER NOT NULL,   -- units already inbound
    PRIMARY KEY (snapshot_date, store_id, sku)
);

CREATE INDEX idx_inv_sku   ON inventory_daily(sku);
CREATE INDEX idx_inv_store ON inventory_daily(store_id);
CREATE INDEX idx_inv_date  ON inventory_daily(snapshot_date);
