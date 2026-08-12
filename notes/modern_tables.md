# Aligning the full table set (`align_tables.R`)

Two output families under `aligned/` at the data destination, extending the
Table 4 treatment (see [table4.md](table4.md)) to the rest of the publication.

## 1. Modern panels — every table, 2014–2022

`aligned/modern/{table_id}.csv`, one per basic table, long format:
`tax_year, row_seq, section, row_label, col_seq, col_label, value, flag,
unit`. Cells key across years on `(row_label, col_label)` — labels are as
published, normalized (footnote refs, dot leaders, whitespace wraps
stripped). `aligned/modern/_coverage.csv` records how many years each label
appears in; consult it before assuming a series is continuous.

Label stability observed (rows / columns present in all published years):

- Fully or near-fully stable: 3.2, 8, 9, 10, 11, 12, 14 (columns), 1/1cv
  (columns).
- Industry dimensions drift with NAICS revisions (mostly the TY2017 update):
  Table 1/1cv rows (208/283 stable), 5.x columns (~177/243), 6.x/7 columns
  (~77/107). The drifted labels are renames/splits of minor industries; a
  proper industry concordance is needed to bridge them.
- **Table 13 rows are 1/76 stable — by design, not a bug**: through 2016 the
  file holds Table 13.1 (non-S/REIT/RIC only) and its item stubs differ from
  the 2017+ all-corporation Table 13. Treat 2014–16 and 2017–22 as separate
  series.
- The 2.x asset-class column labels vary textually year to year (merged-cell
  echoes, "Total" vs "Total assets") — use the deep panels below, which
  canonicalize them, rather than matching generic 2.x column labels.

Units: `count` for "Number of ..." rows (columns for the industry-row
Tables 1/1cv), `pct` for 2.1A/2.4A, `cv_pct` for Table 1 part 2, else
`thousand_usd`. Flags as in table4.md, plus `[n]` for footnote-only cells
(e.g. "[2]" = rounds to zero in 2.1A) and `blank` for empty cells in
otherwise-data rows.

## 2. Deep panels — 1994–2022 for the size-class pairs

`aligned/table_02_1.csv`, `aligned/table_02_2.csv`, `aligned/table_03_1.csv`:
`tax_year, item, col_type (total | zero_assets | size_class), size_class,
class_lo, class_hi, value, flag, unit`.

| Panel | Modern table | Old table (1994–2013) | Classifier |
|---|---|---|---|
| table_02_1 | 2.1 all active corps | 2 | size of total assets |
| table_02_2 | 2.2 returns with net income | 3 | size of total assets |
| table_03_1 | 3.1 selected items | 5 (All-Industries block) | size of business receipts |

Mechanics and gotchas:

- **Class bounds**: modern 2.1/2.2 publish asset-class bounds in THOUSANDS
  ("$1 under $500" = $1 under $500,000, per their own footnote); old
  vintages and 3.1 use whole dollars. Bounds are scaled to whole dollars and
  canonical `size_class` labels rebuilt after scaling, so classes match
  across eras. A published lower bound of $1 stays $1.
- **Brackets changed over time** (finer small-asset classes pre-2005; the
  receipts brackets changed in 2004 and 2014). The panel keeps each year's
  published classes — `total` (and `zero_assets` for 2.1/2.2) are the
  continuous columns; align on `class_lo`/`class_hi` when comparing class
  detail across eras. 1994–2003 Table 5 additionally publishes an
  overlapping "Under $100,000" SUBTOTAL column alongside its finer
  sub-classes — don't sum classes without checking overlap via the bounds.
- **Old Table 5 is sector-blocked** (its item stub repeats per sector, >1,000
  rows); only the leading All-Industries block is kept, truncated at the
  first sector header. 1994–2003 vintages wrap one combined asset item over
  two stub lines; it appears as "cash, govt. obligations, tax-exempt
  securities, and other current assets".
- **Item harmonization**: `ITEM_ALIASES` in align_tables.R maps label drift
  to the modern label ("taxes paid"→"taxes and licenses", "rents"→"gross
  rents", "contributions or gifts"→"charitable contributions", the
  stockholders→shareholders and mortgages/notes/bonds renames, capital-gain
  phrasings, "income tax, total" (94–95)→"total income tax before credits",
  etc.). Every cross-era merge was verified by value continuity at the seam
  before adoption. Result: 61 of 99 items span all 29 years in 2.1/2.2
  (13 of 83 in 3.1, whose item set was redesigned in 2004 and 2014); the
  rest are era-specific items (e.g. old-only U.S. possessions credit rows,
  modern-only "domestic production activities deduction") — check coverage
  with `table(panel$item, panel$tax_year)` before using an item.
- Items deliberately NOT merged (concepts differ): old 3.1 "accounts and
  notes payable" (includes short-term notes) vs modern "accounts payable";
  old "other investments and loans" vs "other investments"; old separate
  domestic/foreign dividends vs modern combined "dividends"; old Table 2
  "income tax" (the regular-tax component, distinct from "total income tax
  before credits", both present 1996–2013).
- Verified at the seams: number of returns, total assets, total receipts,
  and net income are smooth across 1997/98, 2003/04, and 2013/14; Table 2.1
  and 3.1 totals agree exactly (same population), Table 2.2 is the
  with-net-income subset.

## Industry-dimension machinery (the Tier 1 engine prerequisite, done 2026-08)

`extract_sheet` handles the industry-table shapes and emits two hierarchy
columns in every panel (modern CSVs gained them in the same rerun; values
unchanged, verified cell-by-cell against the pre-change outputs):

- **Stacked lower blocks, of two kinds.** `find_numrows()` finds continuation
  column-number rows (each must contain nothing but its number run) and tells
  the two layouts apart by how the numbering runs:
  - **more columns** (`kind = 'cols'`, numbering resumes at prev+1) — 1996
    Table 1 puts columns 1–20 in rows 1–308 and repeats title + stub below
    with columns 21–40. `col_seq` continues across the blocks.
  - **more rows** (`kind = 'rows'`, numbering repeats) — the 2001 Table 1 CV
    file is *paginated*: columns 21–40 printed on four pages, each with its
    own title block, stub header and number row, carrying a different slice of
    industries. `col_seq` restarts and the rows are appended.

  2004+ splits column panels into separate files instead
  (`04co01accr.xls`/`04co01bccr.xls`) — a file-map concern for the spec, not
  the parser. Horizontally repeated stub panels (1996 Table 2, and the
  two/three-panel Table 1 vintages) already worked: the column-number run
  simply skips the repeated stub columns.
- **`row_indent`** — leading spaces of the stub cell as published, the row
  hierarchy of the Table 1 family in ALL eras (readxl's default `trim_ws`
  was destroying it in the xlsx era; `read_sheet_matrix` now preserves it).
  Indent WIDTHS are not comparable across files or even blocks (2013 Table
  1 indents Agriculture minors 4 spaces, Mining minors 6), so specs should
  classify on indent == 0 vs > 0 (plus the 1998–2000 supersector rows),
  not on absolute width.
- **`col_group`** — ' > '-joined industry spanners covering the column,
  from real merged-cell ranges (`sheet_merges()`: sheet XML for xlsx,
  xlrd via `read_xls_merges.py` for .xls). Positional inference is NOT
  used — it cannot work, single-column sectors (Mining, Utilities) sit
  between multi-column spanners. Availability follows what the file
  format recorded: all 17 multi-column sectors in the modern 5.x, most
  2013-era .xls, only some 2004-era .xls, and NOTHING before ~2003 (no
  merge records) — there `col_group` is ''. Sector-TOTAL columns don't
  need it in any era: the spanner text physically sits in the sector's
  first column, so their stacked `col_label` reads "Mining Total",
  "Construction Total", etc.

## Old-table counterparts NOT deep-aligned (roadmap)

From SOI's crosswalk (docs/table_crosswalk_2014.pdf), with why:

| Modern | Old | Blocker |
|---|---|---|
| 1, 1cv | 1, 1cv | rows are minor industries — SIC pre-1998, NAICS revisions after; needs an industry concordance |
| 5.1/5.2/5.3/5.4 | 6/7/12/13 | columns (modern) / rows (old) are industries; same concordance problem |
| 6.1/6.2, 7, 8, 9, 3.2 | 1120S tables 7/8, 1, 5, 6, 4 | the `{yy}co0Xs.xls` 1120S files appear in the zips only for later years; industry dimension for 6.x/7 |
| 10, 11, 12 | 10, 20, 26 | industry/sector dimension |
| 2.4 | Corporation Source Book 3 | source book not part of this archive |
| 2.1A, 2.3, 2.4A, 3.3, 13, 14 | n/a | no pre-2014 counterpart published |

The generic engine (extract_sheet + parse_class_header + aliases) is the
intended base for any of these: add a spec with the per-era file map and
curate labels from the coverage report, exactly as the three deep panels
were built.
