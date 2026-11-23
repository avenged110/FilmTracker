#!/usr/bin/env python3
# Copyright © 2026 avenged110.
# SPDX-License-Identifier: GPL-3.0-only
"""Compares two Film Tracker stores row for row, independent of Core Data's internal numbering.

Usage: compare_stores.py <before.sqlite> <after.sqlite>

Every entity table the BEFORE store has (Z<ENTITY>, not Z_ bookkeeping) must hold the same rows
in AFTER: rows are matched by the table's ID column, every attribute column is compared, and
every to-one reference (a column holding another table's Z_PK) is compared by the referenced
row's ID, so a migration that renumbers Z_PK or Z_ENT still compares equal. Tables only AFTER
has are listed with their row counts. Exits 0 when every shared table matches.
"""
import sqlite3
import sys

ID_COLUMNS = {
    "ZFILM": "ZID", "ZLISTOBJECT": "ZLISTID", "ZLISTMEMBERSHIP": "ZID", "ZRELEASE": "ZID",
    "ZIMPORTSESSION": "ZID", "ZSETTINGSOBJECT": "ZSNAPSHOTID", "ZSAVEDSEARCHOBJECT": "ZSEARCHID",
    "ZFILMLINK": "ZID",
}
# (table, column) → referenced table.
REFERENCES = {
    ("ZRELEASE", "ZFILM"): "ZFILM", ("ZRELEASE", "ZPARENTRELEASE"): "ZRELEASE",
    ("ZLISTMEMBERSHIP", "ZFILM"): "ZFILM", ("ZLISTMEMBERSHIP", "ZLIST"): "ZLISTOBJECT",
    ("ZFILMLINK", "ZSOURCEFILM"): "ZFILM", ("ZFILMLINK", "ZTARGETFILM"): "ZFILM",
}
BOOKKEEPING = {"Z_PK", "Z_ENT", "Z_OPT"}


def open_ro(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def tables(db):
    return sorted(r[0] for r in db.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'Z%' AND name NOT LIKE 'Z\\_%' ESCAPE '\\'"))


def columns(db, table):
    return [r[1] for r in db.execute(f"PRAGMA table_info({table})")]


def id_by_pk(db, table):
    column = ID_COLUMNS.get(table)
    if not column:
        return {}
    return {pk: ident for pk, ident in db.execute(f"SELECT Z_PK, {column} FROM {table}")}


def rows(db, table, cols, pk_maps):
    id_col = ID_COLUMNS.get(table)
    result, unkeyed = {}, 0
    for row in db.execute(f"SELECT {', '.join(cols)} FROM {table}"):
        record = dict(zip(cols, row))
        values = []
        for col in cols:
            if col in BOOKKEEPING:
                continue
            value = record[col]
            target = REFERENCES.get((table, col))
            if target is not None and value is not None:
                value = ("ref", pk_maps[target].get(value, f"dangling:{value}"))
            values.append((col, value))
        key = record.get(id_col) if id_col else None
        if key is None:
            unkeyed += 1
            key = ("unkeyed", unkeyed, tuple(values))
        result[key] = tuple(values)
    return result


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    before, after = open_ro(sys.argv[1]), open_ro(sys.argv[2])
    before_tables, after_tables = tables(before), tables(after)
    ok = True
    pk_before = {t: id_by_pk(before, t) for t in ID_COLUMNS if t in before_tables}
    pk_after = {t: id_by_pk(after, t) for t in ID_COLUMNS if t in after_tables}
    total = 0
    for table in before_tables:
        if table not in after_tables:
            print(f"MISSING  {table}: gone after migration")
            ok = False
            continue
        cols_before, cols_after = columns(before, table), columns(after, table)
        lost = [c for c in cols_before if c not in cols_after]
        added = [c for c in cols_after if c not in cols_before]
        if lost:
            print(f"COLUMNS  {table}: lost {lost}")
            ok = False
        shared = [c for c in cols_before if c in cols_after]
        a, b = rows(before, table, shared, pk_before), rows(after, table, shared, pk_after)
        missing = [k for k in a if k not in b]
        extra = [k for k in b if k not in a]
        changed = [k for k in a if k in b and a[k] != b[k]]
        total += len(a)
        status = "OK" if not (missing or extra or changed) else "DIFFERS"
        ok = ok and status == "OK"
        note = f", new columns {added}" if added else ""
        print(f"{status:8} {table}: {len(a)} → {len(b)} row(s); missing {len(missing)}, "
              f"extra {len(extra)}, changed {len(changed)}{note}")
        for key in changed[:3]:
            diffs = [(c, x, y) for (c, x), (_, y) in zip(a[key], b[key]) if x != y]
            print(f"         e.g. {key}: {diffs[:4]}")
    for table in after_tables:
        if table not in before_tables:
            count = after.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            print(f"NEW      {table}: {count} row(s), columns {columns(after, table)}")
    print(f"{'PASS' if ok else 'FAIL'}: {total} row(s) across {len(before_tables)} pre-existing table(s) compared")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
