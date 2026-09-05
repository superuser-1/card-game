#!/usr/bin/env python3
"""Rebuild data/cards.json by joining extra columns onto the existing card list.

Sources:
  - data/cards.json            existing cards (clean UTF-8 titles/names; the
                               canonical id + base-stat list)
  - source_data/Movie_DB.xlsx  joined by Movie_ID for:
                                 Calculated User Rating -> audience_score
                                 Director Oscar Wins    -> director_oscars_won
                                 (overridden per data/director_oscars_overrides.json
                                 where the xlsx disagrees with itself across a
                                 director's own films — see that file's comment)
  - data/director_birth_years.json  person -> birth year, for:
                                 director_birth_year      (co-directed films:
                                   mean of the co-directors, rounded; null if
                                   ANY co-director's year is unknown)
                                 director_age_at_release  = release_year - birth

Also derives profit_cost_ratio_pct = round((box_office_usd - budget_usd) /
budget_usd * 100) from the existing box_office_usd/budget_usd fields already on
each card (null if either is null or budget_usd is 0 — same nullability as the
box_office/budget categories).

Re-runnable and idempotent. Requires openpyxl (`pip install openpyxl`).

Usage:  python scripts/build_cards.py
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CARDS = ROOT / "data" / "cards.json"
XLSX = ROOT / "source_data" / "Movie_DB.xlsx"
BIRTHS = ROOT / "data" / "director_birth_years.json"
OSCAR_OVERRIDES = ROOT / "data" / "director_oscars_overrides.json"

SPLIT_RE = re.compile(r"\s+and\s+|,\s*|;\s*")


def split_directors(name: str) -> list[str]:
    return [p.strip() for p in SPLIT_RE.split(name) if p.strip()]


def main() -> int:
    try:
        import openpyxl
    except ImportError:
        print("ERROR: openpyxl not installed.  pip install openpyxl", file=sys.stderr)
        return 1

    cards_doc = json.loads(CARDS.read_text(encoding="utf-8"))
    cards = cards_doc["cards"]

    wb = openpyxl.load_workbook(XLSX, data_only=True)
    ws = wb.active
    rows = list(ws.iter_rows(values_only=True))
    hdr = list(rows[0])
    ci_id = hdr.index("Movie_ID")
    ci_rating = hdr.index("Calculated User Rating")
    ci_doscars = hdr.index("Director Oscar Wins")
    xl = {r[ci_id]: r for r in rows[1:]}

    births = json.loads(BIRTHS.read_text(encoding="utf-8"))["years"]
    oscar_overrides = json.loads(OSCAR_OVERRIDES.read_text(encoding="utf-8"))["overrides"]

    missing_people = set()
    n_birth_ok = 0
    n_oscar_overridden = 0
    for c in cards:
        row = xl.get(c["id"])
        if row is None:
            print(f"WARN: no xlsx row for {c['id']} ({c['title']})", file=sys.stderr)
            c["audience_score"] = None
            c["director_oscars_won"] = None
        else:
            c["audience_score"] = int(row[ci_rating]) if row[ci_rating] is not None else None
            c["director_oscars_won"] = int(row[ci_doscars]) if row[ci_doscars] is not None else None

        people = split_directors(c["director"])

        # Career-Oscar overrides win over the xlsx value. For a multi-director
        # credit, use the MAX of whichever named people have an override (the
        # more Oscar-decorated of the pair); a co-director with no override
        # doesn't block the other's override from applying.
        override_vals = [oscar_overrides[p] for p in people if p in oscar_overrides]
        if override_vals:
            new_val = max(override_vals)
            if c["director_oscars_won"] != new_val:
                n_oscar_overridden += 1
            c["director_oscars_won"] = new_val
        years = []
        unknown = False
        for p in people:
            y = births.get(p)
            if y is None:
                unknown = True
                if p not in births:
                    missing_people.add(p + "  (not in director_birth_years.json)")
                else:
                    missing_people.add(p)
            else:
                years.append(int(y))
        if unknown or not years:
            c["director_birth_year"] = None
            c["director_age_at_release"] = None
        else:
            by = round(sum(years) / len(years))
            c["director_birth_year"] = by
            c["director_age_at_release"] = int(c["release_year"]) - by
            n_birth_ok += 1

        bo = c.get("box_office_usd")
        bu = c.get("budget_usd")
        if bo is None or bu is None or bu == 0:
            c["profit_cost_ratio_pct"] = None
        else:
            c["profit_cost_ratio_pct"] = round((bo - bu) / bu * 100)

    CARDS.write_text(
        json.dumps(cards_doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print(f"wrote {len(cards)} cards to {CARDS.relative_to(ROOT)}")
    print(f"  director_age_at_release resolved: {n_birth_ok}/{len(cards)}")
    print(f"  director_oscars_won overridden: {n_oscar_overridden} card(s)")
    if missing_people:
        print(f"  {len(missing_people)} directors still missing a birth year:")
        for p in sorted(missing_people):
            print(f"    - {p}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
