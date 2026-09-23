"""Synthetic data for the melt-shop SQL portfolio.

Everything here is invented. The generator reproduces the *shape* of a real
melting shop — campaigns of the same product, idle periods, a control system
that does not log every furnace, lots that spill over between consecutive
orders — without any real figures.

Deterministic: the same seed always produces the same file.

    python3 data/generate_seed.py > data/02_seed_data.sql
"""
import datetime as dt
import math
import random
import sys

SEED = 20260924
rnd = random.Random(SEED)

START = dt.datetime(2020, 1, 6, 6, 0)
END = dt.datetime(2026, 8, 31, 23, 0)

# ── Furnaces ─────────────────────────────────────────────────────────────────
# a = standing gas (Nm3/h just to keep the furnace hot), b = melting gas (Nm3/t)
FURNACES = {
    'C01': dict(type='continuous', scada=1, year=2008, kgh=480, a=62, b=92),
    'C02': dict(type='continuous', scada=1, year=2011, kgh=430, a=48, b=110),
    'C03': dict(type='continuous', scada=1, year=2006, kgh=560, a=75, b=84),
    'C04': dict(type='continuous', scada=1, year=2014, kgh=505, a=58, b=98),
    'C05': dict(type='continuous', scada=1, year=2016, kgh=455, a=52, b=104),
    'C06': dict(type='continuous', scada=1, year=2019, kgh=530, a=66, b=88),
    'T01': dict(type='tilting',    scada=0, year=2012, kgh=190, a=14, b=150),
    'R01': dict(type='rotary',     scada=0, year=2010, kgh=160, a=18, b=210),
}
OXYGEN_FROM = {'C02': dt.datetime(2021, 6, 20), 'C05': dt.datetime(2023, 2, 14)}
# The control system stopped logging C03 for a while: production went on,
# the historian recorded nothing. Level 2 has to tell this apart from
# "furnace has no SCADA".
LOGGING_GAP = ('C03', dt.datetime(2021, 3, 1), dt.datetime(2022, 10, 31))

# ── Products ─────────────────────────────────────────────────────────────────
FAMILIES = ['opaque'] * 16 + ['transparent'] * 14 + ['matte'] * 10
rnd.shuffle(FAMILIES)
PRODUCTS = []
for i, fam in enumerate(FAMILIES):
    prefix = {'opaque': 'OPQ', 'transparent': 'TRN', 'matte': 'MAT'}[fam]
    PRODUCTS.append(dict(
        code=f'{prefix}-{101 + i}', family=fam,
        loss=rnd.uniform(4.5, 8.5) + (2.2 if fam == 'transparent' else 0),
        speed=rnd.uniform(0.86, 1.14),
        gas=rnd.uniform(0.92, 1.12),
        weight=1 / (i + 1) ** 0.95,           # a few products dominate tonnage
        material=rnd.uniform(24, 33) if fam == 'opaque' else rnd.uniform(19, 26),
    ))
SMALL_ONLY = [p for p in PRODUCTS if p['family'] == 'matte'][:6]   # batch furnaces

TARIFF = {2020: 7.9, 2021: 9.8, 2022: 21.5, 2023: 16.2, 2024: 13.1, 2025: 12.4, 2026: 12.0}
DESCR = {'opaque': 'zirconium-opacified frit', 'transparent': 'clear glossy frit',
         'matte': 'matt frit, low gloss'}


def pick(pool):
    return rnd.choices(pool, weights=[p['weight'] for p in pool])[0]


def years_since(events, when):
    past = [e for e in events if e <= when]
    return (when - max(past)).days / 365.25 if past else 4.0


# ── Maintenance ──────────────────────────────────────────────────────────────
MAINT = []   # (furnace, date, type)
OVERHAULS = {}
for code, f in FURNACES.items():
    if f['type'] != 'continuous':
        continue
    d = dt.datetime(2018, 1, 1) + dt.timedelta(days=rnd.randint(0, 700))
    dates = [d]
    while True:
        d = d + dt.timedelta(days=int(365.25 * rnd.uniform(3.0, 4.2)))
        if d > END:
            break
        dates.append(d)
    OVERHAULS[code] = dates
    for d in dates:
        if d >= START:
            MAINT.append((code, d.date(), 'general overhaul'))
    # one smaller repair between overhauls
    mid = dates[-1] - dt.timedelta(days=rnd.randint(300, 600))
    if mid >= START:
        MAINT.append((code, mid.date(), 'lining repair'))
for code, d in OXYGEN_FROM.items():
    MAINT.append((code, d.date(), 'conversion to oxygen'))
MAINT.sort(key=lambda x: (x[1], x[0]))

# ── Melts ────────────────────────────────────────────────────────────────────
melts, regime, lots = [], [], []
order_no = 20200001
lot_no = 1


def next_order():
    global order_no
    order_no += rnd.randint(1, 7)
    return order_no


for code, f in FURNACES.items():
    t = START + dt.timedelta(hours=rnd.randint(0, 400))
    small = f['type'] != 'continuous'
    overhauls = OVERHAULS.get(code, [])
    while t < END:
        # furnace down for overhaul: skip ~6 weeks around the date
        stop = [d for d in overhauls if d - dt.timedelta(days=14) <= t < d + dt.timedelta(days=35)]
        if stop:
            t = stop[0] + dt.timedelta(days=35)
            continue
        # campaign: one product, 1..6 consecutive orders
        prod = pick(SMALL_ONLY if small else PRODUCTS)
        n = rnd.choices([1, 2, 3, 4, 5, 6], weights=[30, 24, 18, 12, 9, 7])[0]
        campaign = []
        for _ in range(n):
            if t >= END:
                break
            size_t = rnd.uniform(3, 9) if small else max(12, rnd.lognormvariate(math.log(46), 0.35))
            kgh = f['kgh'] * prod['speed'] * (1 + 0.0025 * (size_t - 50)) * rnd.uniform(0.94, 1.06)
            hours = size_t * 1000 / kgh
            start = t
            end = t + dt.timedelta(hours=hours)
            if end > END:             # the data set ends on END, no half-finished melts
                t = END
                break
            # ageing lining: +2.5 % gas per year since the last overhaul
            age = years_since(overhauls, start) if overhauls else 2.0
            oxy = code in OXYGEN_FROM and start >= OXYGEN_FROM[code]
            a = f['a'] * (0.8 if oxy else 1.0)
            b = f['b'] * (0.70 if oxy else 1.0) * prod['gas'] * (1 + 0.025 * min(age, 5))
            gas = (a * hours + b * size_t) * rnd.uniform(0.96, 1.04)
            loss = max(1.0, prod['loss'] + rnd.gauss(0, 1.1))
            output = size_t * 1000
            charge = output / (1 - loss / 100)
            campaign.append(dict(
                melt_id=None, furnace=code, product=prod['code'], family=prod['family'],
                start=start, end=end, hours=hours, charge=charge, output=output,
                gas=gas, oxygen=gas * rnd.uniform(1.92, 2.08) if oxy else None,
                loss=loss, prod_loss=prod['loss'], material=prod['material']))
            t = end + dt.timedelta(hours=rnd.choice([0, 0, 1, 2, 6, 24, 72, 120]))
        # spill-over between consecutive orders of the same campaign: part of
        # one order's frit is booked to the next one
        for x, y in zip(campaign, campaign[1:]):
            if rnd.random() < 0.3:
                moved = x['output'] * rnd.uniform(0.02, 0.08)
                x['output'] -= moved
                y['output'] += moved
        melts.extend(campaign)
        # idle between campaigns, now and then a long stop
        t += dt.timedelta(days=rnd.uniform(3, 30) if rnd.random() > 0.08 else rnd.uniform(60, 150))

# order numbers are issued in time order across the whole plant, not per furnace
melts.sort(key=lambda m: (m['start'], m['furnace']))
for m in melts:
    m['melt_id'] = next_order()

for m in melts:
    y = m['start'].year
    # charge was not weighed before 2021 on most orders
    if y < 2021 and rnd.random() < 0.7:
        m['charge_out'] = None
    else:
        m['charge_out'] = m['charge']
    m['electricity'] = (m['output'] / 1000 * rnd.uniform(38, 72)) if y >= 2024 else None
    if y >= 2024:
        m['material_cost'] = m['material'] * rnd.uniform(0.97, 1.03)
        m['conversion_cost'] = m['gas'] / m['output'] * TARIFF[y] + rnd.uniform(2.9, 3.6)
    else:
        m['material_cost'] = m['conversion_cost'] = None

    # control system
    f = FURNACES[m['furnace']]
    in_gap = (m['furnace'] == LOGGING_GAP[0] and LOGGING_GAP[1] <= m['start'] <= LOGGING_GAP[2])
    if f['scada'] and not in_gap and rnd.random() > 0.03:
        t1 = 1485 + (int(m['furnace'][1:]) - 3) * 7 + (m['prod_loss'] - 7) * 4 + rnd.gauss(0, 9)
        # C02 has an auxiliary roof burner that the flow meter does not see
        seen = 0.80 if m['furnace'] == 'C02' else 0.94
        regime.append(dict(melt_id=m['melt_id'], readings=int(m['hours'] * 12),
                           t1=t1, t3=t1 - rnd.gauss(232, 18),
                           flow=m['gas'] / m['hours'] * seen * rnd.uniform(0.97, 1.03)))

    # quality: lots of 5-10 t (1-2 lots on batch furnaces)
    if rnd.random() < 0.02:
        continue                      # a few melts never got a QC decision
    remaining = m['output']
    decided = m['end'] + dt.timedelta(hours=rnd.randint(2, 30))
    # the further the melt's loss is from its product's usual loss, the more
    # likely a problem lot — a pattern level 3 can find again
    dev = abs(m['loss'] - m['prod_loss'])
    while remaining > 1:
        q = min(remaining, rnd.uniform(5000, 10000))
        remaining -= q
        p_rej = 0.004 + 0.006 * dev
        p_rem = (0.045 if y < 2024 else 0.011) + 0.01 * dev   # rule change in 2024
        r = rnd.random()
        if r < p_rej:
            code = 'REJECT'
        elif r < p_rej + p_rem:
            code = 'REMELT'
        else:
            code = rnd.choices(['OK', 'OK-MINOR', 'OK-MAJOR'],
                               weights=[74, 13, 13 if y < 2024 else 16])[0]
        lots.append((lot_no, m['melt_id'], code, q, decided))
        lot_no += 1
        decided += dt.timedelta(minutes=rnd.randint(5, 90))

# orphans: QC lots for orders the production table does not have
for i in range(23):
    lots.append((lot_no, 19990000 + i * 13, rnd.choice(['OK', 'OK-MINOR']),
                 rnd.uniform(800, 1500),
                 START + dt.timedelta(days=rnd.randint(0, 2000), minutes=rnd.randint(0, 1439))))
    lot_no += 1


# ── SQL ──────────────────────────────────────────────────────────────────────
def q(v, d=1):
    if v is None:
        return 'NULL'
    if isinstance(v, str):
        return "'" + v.replace("'", "''") + "'"
    if isinstance(v, (dt.datetime,)):
        return "'" + v.strftime('%Y-%m-%d %H:%M:%S') + "'"
    if isinstance(v, dt.date):
        return "'" + v.isoformat() + "'"
    if isinstance(v, int):
        return str(v)
    return f'{v:.{d}f}'


def insert(table, cols, rows, batch=400):
    out = []
    for i in range(0, len(rows), batch):
        chunk = rows[i:i + batch]
        out.append(f'INSERT INTO {table} ({", ".join(cols)}) VALUES\n' +
                   ',\n'.join('(' + ','.join(r) + ')' for r in chunk) + ';')
    return '\n'.join(out)


w = sys.stdout.write
w('-- =============================================================================\n'
  '-- 02_seed_data.sql  ·  synthetic data, generated by data/generate_seed.py\n'
  f'-- seed {SEED}. Do not edit by hand: change the generator and regenerate.\n'
  '-- =============================================================================\n\n'
  'USE melt_shop;\nSET NAMES utf8mb4;\n\n')

w(insert('furnaces', ['furnace_code', 'furnace_type', 'has_scada', 'commissioned'],
         [[q(c), q(f['type']), q(f['scada']), q(f['year'])] for c, f in FURNACES.items()]) + '\n\n')
w(insert('products', ['product_code', 'family', 'description'],
         [[q(p['code']), q(p['family']), q(DESCR[p['family']])] for p in PRODUCTS]) + '\n\n')
w(insert('decision_codes', ['decision_code', 'category', 'description'], [
    [q('OK'), q('conforming'), q('meets specification')],
    [q('OK-MINOR'), q('conforming'), q('minor deviation, released')],
    [q('OK-MAJOR'), q('conforming'), q('larger deviation, released to secondary stock')],
    [q('REMELT'), q('remelt'), q('blended back into a later melt')],
    [q('REJECT'), q('rejected'), q('does not conform, scrapped')],
]) + '\n\n')
w(insert('energy_tariffs', ['tariff_year', 'gas_per_nm3'],
         [[q(y), q(v, 3)] for y, v in TARIFF.items()]) + '\n\n')
w(insert('maintenance_events', ['furnace_code', 'event_date', 'event_type'],
         [[q(c), q(d), q(tp)] for c, d, tp in MAINT]) + '\n\n')
w(insert('melts', ['melt_id', 'furnace_code', 'product_code', 'start_ts', 'end_ts', 'hours',
                   'charge_kg', 'output_kg', 'gas_nm3', 'oxygen_nm3', 'electricity_kwh',
                   'material_cost_per_kg', 'conversion_cost_per_kg'],
         [[q(m['melt_id']), q(m['furnace']), q(m['product']), q(m['start']), q(m['end']),
           q(m['hours'], 2), q(m['charge_out']), q(m['output']), q(m['gas']), q(m['oxygen']),
           q(m['electricity']), q(m['material_cost'], 3), q(m['conversion_cost'], 3)]
          for m in melts]) + '\n\n')
w(insert('furnace_regime', ['melt_id', 'readings', 't1_c', 't3_c', 'gas_flow_nm3h'],
         [[q(r['melt_id']), q(r['readings']), q(r['t1']), q(r['t3']), q(r['flow'], 2)]
          for r in regime]) + '\n\n')
w(insert('quality_lots', ['lot_id', 'melt_id', 'decision_code', 'qty_kg', 'decided_at'],
         [[q(a), q(b), q(c), q(d), q(e)] for a, b, c, d, e in lots]) + '\n\n')

w('-- control counts\n'
  'SELECT (SELECT COUNT(*) FROM melts) AS melts, (SELECT COUNT(*) FROM furnace_regime) AS regime_rows,\n'
  '       (SELECT COUNT(*) FROM quality_lots) AS lots, (SELECT COUNT(*) FROM maintenance_events) AS events;\n')
print(f'-- melts {len(melts)}, regime {len(regime)}, lots {len(lots)}, maintenance {len(MAINT)}',
      file=sys.stderr)
