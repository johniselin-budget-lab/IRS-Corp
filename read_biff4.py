#!/usr/bin/env python3
"""Print the first sheet of a legacy Excel file as CSV on stdout.

The 1994-2002 Corporation Complete Report .xls files (except 1996 and 2003+)
are BIFF4 'Microsoft Excel 4.0 Worksheet' files, which R's readxl/libxls
cannot open. xlrd reads them fine; align_table4.R shells out to this script
for those years. Requires: python3 -m pip install --user xlrd
"""

import csv
import sys

import xlrd

if len(sys.argv) != 2:
    sys.exit("usage: read_biff4.py <file.xls>")

sheet = xlrd.open_workbook(sys.argv[1]).sheet_by_index(0)
writer = csv.writer(sys.stdout)
for i in range(sheet.nrows):
    writer.writerow([sheet.cell_value(i, j) for j in range(sheet.ncols)])
