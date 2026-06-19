import os, psycopg2, uuid, random, datetime

PG_HOST = os.environ["PG_HOST"]
PG_USER = os.environ.get("PG_USER", "application")
CONN_STR = f"host={PG_HOST} port=5432 dbname=postgres user={PG_USER} sslmode=require"

PRODUCTS = [
    ("P001","Wireless Headphones","Electronics",89.99),
    ("P002","Running Shoes","Sports",129.99),
    ("P003","Coffee Maker","Home & Garden",79.99),
    ("P004","Python Programming Book","Books",49.99),
    ("P005","Yoga Mat","Sports",34.99),
    ("P006","Bluetooth Speaker","Electronics",59.99),
    ("P007","Winter Jacket","Clothing",199.99),
    ("P008","Skincare Set","Beauty",74.99),
    ("P009","Kids LEGO Set","Toys",44.99),
    ("P010","Office Chair","Office",299.99),
    ("P011","Protein Powder","Food",39.99),
    ("P012","Smart Watch","Electronics",249.99),
    ("P013","Sunglasses","Clothing",89.99),
    ("P014","Garden Tools Set","Home & Garden",54.99),
    ("P015","Car Phone Mount","Automotive",19.99),
]

conn = psycopg2.connect(CONN_STR)
cur  = conn.cursor()

cur.execute("SELECT order_id, order_date FROM retail.orders")
orders = cur.fetchall()
print(f"Fetched {len(orders)} orders. Generating order_items...", flush=True)

batch, batch_size = [], 500
total = 0
for oid, order_ts in orders:
    n_items = random.randint(1, 5)
    for pid, pname, cat, price in random.sample(PRODUCTS, n_items):
        qty = random.randint(1, 3)
        batch.append((str(uuid.uuid4()), oid, pid, pname, cat, qty, price, order_ts))
    if len(batch) >= batch_size:
        cur.executemany(
            "INSERT INTO retail.order_items VALUES (%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
            batch
        )
        conn.commit()
        total += len(batch)
        print(f"  {total} items inserted...", flush=True)
        batch = []

if batch:
    cur.executemany(
        "INSERT INTO retail.order_items VALUES (%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
        batch
    )
    conn.commit()
    total += len(batch)

cur.close()
conn.close()
print(f"Done. {total} order_items loaded.")
