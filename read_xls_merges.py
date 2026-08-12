#!/usr/bin/env python3
"""Print the first sheet's merged-cell ranges of an .xls file as CSV rows
first_row,last_row,first_col,last_col (1-based inclusive) on stdout.

Used by alignment_helpers.R::sheet_merges() to recover the industry
spanner extents in the column-industry tables. BIFF8 files (2003+) carry
merge records; the 1994-2002 BIFF4-era files do not (xlrd then reports
none, or fails on formatting_info) -- either way this prints nothing and
the caller proceeds without column groups. Requires xlrd (see README).
"""

import sys

import xlrd

if len(sys.argv) != 2:
    sys.exit("usage: read_xls_merges.py <file.xls>")

try:
    book = xlrd.open_workbook(sys.argv[1], formatting_info=True)
except Exception:
    sys.exit(0)   # no merge info available in this vintage
sheet = book.sheet_by_index(0)
for r0, r1, c0, c1 in sorted(sheet.merged_cells):
    # xlrd ranges are 0-based half-open
    print(f"{r0 + 1},{r1},{c0 + 1},{c1}")
