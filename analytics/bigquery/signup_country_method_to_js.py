#!/usr/bin/env python3
"""Convert signup-country-method-daily.sql CSV output into workbench JS data."""

from __future__ import annotations

import csv
import json
import sys
from argparse import ArgumentParser
from collections import defaultdict


COUNTRIES = ["VN", "ID", "MY", "SA", "TH", "KR", "Other"]
VALUE_FIELDS = [
    "first_opens",
    "registered",
    "google",
    "phone",
    "apple",
    "facebook",
    "kakao",
    "unknown",
]


def compact(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


parser = ArgumentParser()
parser.add_argument(
    "--method-start",
    default="2026-07-22",
    help="First date embedded in the country × method drill-down (YYYY-MM-DD)",
)
args = parser.parse_args()

rows = list(csv.DictReader(sys.stdin))
if not rows:
    raise SystemExit("No CSV rows received")

days = sorted({row["cohort_date"] for row in rows})
latest_day = days[-1]
by_key = {(row["cohort_date"], row["country_code"]): row for row in rows}
method_days = [day for day in days if day >= args.method_start]

country_method: dict[str, list[list[int]]] = {}
for country in COUNTRIES:
    country_method[country] = []
    for day in method_days:
        row = by_key.get((day, country))
        country_method[country].append(
            [int(row[field]) if row else 0 for field in VALUE_FIELDS]
        )

daily = []
for day in days:
    day_rows = [row for row in rows if row["cohort_date"] == day]
    sums = defaultdict(int)
    for row in day_rows:
        for field in (
            "first_opens",
            "registered",
            "android_first_opens",
            "android_registered",
        ):
            sums[field] += int(row[field])
    daily.append(
        {
            "d": day[5:] + ("*" if day == latest_day else ""),
            "n": sums["first_opens"],
            "s": sums["registered"],
            "an": sums["android_first_opens"],
            "as": sums["android_registered"],
        }
    )

day_labels = [day[5:] + ("*" if day == latest_day else "") for day in method_days]
print(f"const AUTH_METHOD_DAYS={compact(day_labels)};")
print(f"const AUTH_METHOD_DATA={compact(country_method)};")
print(f"const REG_DAILY={compact(daily)};")
