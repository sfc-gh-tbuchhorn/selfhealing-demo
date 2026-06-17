import psycopg2, uuid, random, datetime, sys

PG_HOST = "gxlnixonmzblpkn7wyegesvry4.sfseapac-au-demo92.ap-southeast-2.aws.postgres.snowflake.app"
CONN_STR = f"host={PG_HOST} port=5432 dbname=postgres user=application sslmode=require"

N_CUSTOMERS   = 500
N_ORDERS      = 2000
N_ITEMS_MAX   = 5

FIRST_NAMES = ["James","Olivia","Liam","Emma","Noah","Ava","Oliver","Sophia","Elijah","Isabella",
               "William","Mia","James","Charlotte","Benjamin","Amelia","Lucas","Harper","Mason","Evelyn"]
LAST_NAMES  = ["Smith","Johnson","Williams","Brown","Jones","Garcia","Miller","Davis","Wilson","Taylor",
               "Anderson","Thomas","Jackson","White","Harris","Martin","Thompson","Young","Lewis","Walker"]
DOMAINS     = ["gmail.com","yahoo.com","outlook.com","icloud.com","hotmail.com"]
COUNTRIES   = ["AU","US","GB","CA","NZ","SG","JP","DE","FR","IN"]
SEGMENTS    = ["Premium","Standard","Basic","VIP","Wholesale"]
CATEGORIES  = ["Electronics","Clothing","Home & Garden","Books","Sports","Toys","Beauty","Food","Automotive","Office"]
STATUSES    = ["completed","completed","completed","pending","shipped","returned","cancelled"]
CHANNELS    = ["web","mobile","in-store","phone"]
PRODUCTS    = [
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

def rand_ts(days_back=365):
    delta = datetime.timedelta(
        days=random.randint(0, days_back),
        hours=random.randint(0, 23),
        minutes=random.randint(0, 59),
        seconds=random.randint(0, 59)
    )
    return datetime.datetime.utcnow() - delta

conn = psycopg2.connect(CONN_STR)
cur  = conn.cursor()

print(f"Inserting {N_CUSTOMERS} customers...", flush=True)
customer_ids = []
for _ in range(N_CUSTOMERS):
    cid = str(uuid.uuid4())
    customer_ids.append(cid)
    fn  = random.choice(FIRST_NAMES)
    ln  = random.choice(LAST_NAMES)
    cur.execute(
        "INSERT INTO retail.customers VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
        (cid, fn, ln, f"{fn.lower()}.{ln.lower()}{random.randint(1,99)}@{random.choice(DOMAINS)}",
         f"+61 4{random.randint(10,99)} {random.randint(100,999)} {random.randint(100,999)}",
         random.choice(COUNTRIES), random.choice(SEGMENTS),
         rand_ts(730), rand_ts(30))
    )

conn.commit()
print(f"Inserting {N_ORDERS} orders + line items...", flush=True)

item_rows = []
for i in range(N_ORDERS):
    oid      = str(uuid.uuid4())
    cid      = random.choice(customer_ids)
    order_ts = rand_ts(365)
    n_items  = random.randint(1, N_ITEMS_MAX)
    items    = random.sample(PRODUCTS, n_items)
    total    = sum(p[3] * random.randint(1,3) for p in items)

    cur.execute(
        "INSERT INTO retail.orders VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
        (oid, cid, order_ts, random.choice(STATUSES), round(total,2),
         "USD", random.choice(CHANNELS), order_ts, order_ts)
    )
    for pid, pname, cat, price in items:
        qty = random.randint(1,3)
        item_rows.append((str(uuid.uuid4()), oid, pid, pname, cat, qty, price, order_ts))

    if (i+1) % 500 == 0:
        conn.commit()
        print(f"  {i+1}/{N_ORDERS} orders committed", flush=True)

cur.executemany(
    "INSERT INTO retail.order_items VALUES (%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
    item_rows
)
conn.commit()
cur.close()
conn.close()

print(f"Done. {N_CUSTOMERS} customers, {N_ORDERS} orders, {len(item_rows)} order items loaded.")
