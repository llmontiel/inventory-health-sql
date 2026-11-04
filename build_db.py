"""
build_db.py
-----------
Build a SQLite inventory-health database from synthetic data, then run the
analytical queries in queries.sql and print the results.

Stdlib only (sqlite3). Simulates daily on-hand/sales snapshots with realistic
stockouts and replenishment, so the health queries have something to find.

    python build_db.py            # build + run all queries
    python build_db.py --rebuild  # drop and rebuild from scratch
"""

import argparse
import os
import random
import sqlite3
from datetime import date, timedelta

DB_PATH = "inventory.db"
RNG = random.Random(99)

STORES = ["STORE_ATX", "STORE_HOU", "STORE_LAX", "STORE_MIA"]
PRODUCTS = {
    # sku:            (category,     lead_time, reorder_point, case_pack, base_demand)
    "SKU_COLA_12PK":   ("Beverage",   3, 40, 12, 18),
    "SKU_WATER_24PK":  ("Beverage",   3, 50, 12, 22),
    "SKU_CEREAL_OAT":  ("Breakfast",  5, 25, 8,  10),
    "SKU_CANDY_BAR":   ("Candy",      4, 60, 24, 28),
    "SKU_CHIPS_FAMILY":("Snacks",     4, 35, 12, 15),
    "SKU_PRETZELS":    ("Snacks",     4, 30, 12, 12),
}

START = date(2025, 1, 1)
DAYS = 120


def build(conn):
    with open("schema.sql") as f:
        conn.executescript(f.read())
    cur = conn.cursor()

    for sku, (cat, lead, rop, cp, _base) in PRODUCTS.items():
        cur.execute("INSERT INTO product VALUES (?,?,?,?,?)", (sku, cat, lead, rop, cp))

    rows = []
    for store in STORES:
        for sku, (cat, lead, rop, cp, base) in PRODUCTS.items():
            # Order-up-to policy: when inventory position drops to the reorder
            # point, order enough cases to reach a target level (~10 days of
            # demand above ROP). Hold healthy stock so turns are realistic and
            # stockouts are the exception, not the norm.
            target_level = rop + base * 10
            on_hand = target_level
            on_order = 0
            inbound_eta = None
            for n in range(DAYS):
                d = START + timedelta(days=n)
                start_on_hand = on_hand  # on-hand recorded at start of day

                # receive inbound order if it has arrived
                if inbound_eta is not None and n >= inbound_eta:
                    on_hand += on_order
                    start_on_hand = on_hand
                    on_order = 0
                    inbound_eta = None

                # demand (weekend lift), capped by what's on the shelf
                weekend = 1.25 if d.weekday() >= 5 else 1.0
                demand = max(0, int(RNG.gauss(base * weekend, base * 0.25)))
                sold = min(demand, on_hand)
                on_hand -= sold

                rows.append((d.isoformat(), store, sku, start_on_hand, sold, on_order))

                # place a replenishment order when position hits reorder point.
                # ~15% of the time an order is delayed a day (supplier variability),
                # which occasionally leaves an item below ROP uncovered -> Q3 flags.
                position = on_hand + on_order
                # Reorder review isn't perfect: ~80% chance the trigger is acted
                # on each day it's hit. The occasional missed review leaves items
                # sitting below ROP uncovered -> surfaced by the Q3 reorder flag.
                if position <= rop and on_order == 0 and RNG.random() < 0.80:
                    shortfall = target_level - position
                    order_cases = max(1, (shortfall + cp - 1) // cp)
                    on_order = order_cases * cp
                    delay = 1 if RNG.random() < 0.15 else 0
                    inbound_eta = n + lead + delay

    cur.executemany("INSERT INTO inventory_daily VALUES (?,?,?,?,?,?)", rows)
    conn.commit()
    return len(rows)


def run_queries(conn):
    with open("queries.sql") as f:
        sql = f.read()

    # Split into statements on ';'. Derive each title from the most recent
    # "-- Qn." banner, then strip comment lines (SQLite runs one stmt at a time).
    blocks = []
    title = None
    for raw_stmt in sql.split(";"):
        code_lines, stmt_title = [], title
        for line in raw_stmt.splitlines():
            s = line.strip()
            if s.startswith("-- Q") and "." in s:
                stmt_title = s.lstrip("- ").strip()
                title = stmt_title
            elif s.startswith("--") or not s:
                continue
            else:
                code_lines.append(line)
        if code_lines:
            blocks.append((stmt_title, "\n".join(code_lines)))

    cur = conn.cursor()
    for title, stmt in blocks:
        cur.execute(stmt)
        cols = [c[0] for c in cur.description]
        data = cur.fetchall()
        print(f"\n{'='*72}\n{title or 'Query'}\n{'='*72}")
        print(" | ".join(cols))
        print("-" * 72)
        for r in data[:10]:
            print(" | ".join(str(x) for x in r))
        if len(data) > 10:
            print(f"... ({len(data)} rows)")


def main(rebuild=False):
    if rebuild and os.path.exists(DB_PATH):
        os.remove(DB_PATH)
    first = not os.path.exists(DB_PATH)
    conn = sqlite3.connect(DB_PATH)
    if first:
        n = build(conn)
        print(f"Built {DB_PATH}: {n:,} daily snapshot rows "
              f"({len(STORES)} stores x {len(PRODUCTS)} SKUs x {DAYS} days).")
    run_queries(conn)
    conn.close()


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--rebuild", action="store_true")
    args = p.parse_args()
    main(rebuild=args.rebuild)
