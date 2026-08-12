# Industry-dimension panels (`align_industry.R`)

The tables classified by industry rather than by size class. Their industry
dimension follows NAICS, which is revised every five years, so they cannot be
aligned by label matching the way the size-class panels are (see
[modern_tables.md](modern_tables.md)) — this note records the decisions that
make them alignable anyway, and the per-vintage quirks found along the way.

## `aligned/table_01.csv` — Table 1 at sector level, 1998–2022

`tax_year, row_type (all_industries | sector | not_allocable), industry, item,
value, flag, unit`. 9,410 cells: 22 industry rows × 20 items in 1998–2005,
thinning to 20 × 15 by 2014 (see the era table below).

### Two deliberate cuts

- **Sector level, not minor industry.** The ~240 minor-industry labels drift
  with every NAICS revision (2002, 2007, 2012, 2017 — ~66 of 243 columns move
  in Table 5.1 at the 2017 revision alone) and would need a curated
  per-revision concordance. The 19 sector labels are stable across the whole
  span. Minor-industry detail stays on the roadmap
  ([alignment_plan.md](alignment_plan.md) Tier 1, item 2).
- **Starts at 1998.** 1994–97 are SIC-coded, not NAICS; only a coarse
  division-level bridge would be defensible, so the panel starts where NAICS
  does. The 1994–97 files remain in the store, unaligned.

### Row selection is by NAME, never by indentation

`extract_sheet` reports `row_indent` (stub leading spaces), but it is unusable
as a level marker for this table:

- 1998–99 wrap the sectors in **supersectors** ("Raw materials & energy
  production", "Goods production", …) that sit at indent 0 with the sectors
  themselves at indent 2 — except **Utilities**, indented 1.
- 2000–2013 drop the supersectors; sectors sit at indent 0, minors at 4, with
  strays at 3.
- The modern files **lose stub indentation progressively**: 2014 still indents
  (0–8), 2015–16 shallower (0–6), and **2017 onwards carry none at all** —
  every row, sector and minor alike, sits at indent 0.

So the aligner matches a canonical list of the 19 sector names (normalized:
lowercased, `&` spelled out, whitespace collapsed) and fails if any year is
missing one. Two consequences worth knowing:

- **Aggregates are excluded by omission**, not by level: the 1998–99
  supersectors and "Wholesale and retail trade" (= wholesale + retail + their
  residual) are simply not in `SECTORS`. Including them would double count.
- **Repeated labels take the first occurrence.** 1998–2003 wrap some
  minor-industry labels so that a lowercase continuation fragment
  ("manufacturing") repeats a sector name further down the stub. A sector row
  always precedes the minors beneath it, so first-by-row-order is the sector.

`row_type = not_allocable` holds the two residual rows SOI publishes 1998–2013
("Wholesale and retail trade not allocable", "Not allocable") — returns it
could not assign to a sector. The modern table has no such rows, so 2014+
yields 20 industry rows against 22 earlier.

### Items are positional, and thin out in three steps

Table 1's columns are variables, not labels (the same situation as Table 4),
so they are mapped **by position** and every mapping is checked against the
published header keyword. The credit detail disappears in stages:

| Years | Data columns | Credit items carried |
|---|---|---|
| 1998–2005 | 20 | foreign, U.S. possessions, nonconventional fuel, general business, prior-year minimum |
| 2006 | 19 | drops nonconventional source fuel credit |
| 2007–2013 | 18 | drops U.S. possessions credit |
| 2014–2022 | 15 | none — only tax before and after credits |

The 15 core items (returns, returns with net income, total receipts, receipts
of returns with net income, business receipts, cost of goods sold, net income,
deficit, income subject to tax, tax before credits, tax after credits, total
assets, net worth, depreciable assets, depreciation deduction) span all 25
years.

### File map, with the naming traps

| Years | File | Note |
|---|---|---|
| 1998–2003 | `archive/{year}/{yy}co01nr.xls` | 1999 and 2001 ship **uppercase** `.XLS`, so the lookup is case-insensitive |
| 2004–2005 | `archive/{year}/{yy}co01accr.xls` | the table is **split in two files**: `a` = estimates, `b` = coefficients of variation. Only `a` is read |
| 2006–2013 | `archive/{year}/{yy}co01ccr.xls` | CVs in a separate `{yy}co01cv.xls` |
| 2014–2022 | `modern/table_01/table_01_{year}.xlsx` | CVs in `modern/table_01_cv/` |

The **1998 and 2013** vintages carry the CV block inside the same sheet as the
estimates (1998 stacks columns 21–40 below the data — see `find_numrows` in
[modern_tables.md](modern_tables.md#industry-dimension-machinery-the-tier-1-engine-prerequisite-done-2026-08);
2013 places 19–36 to the right). The aligner cuts at the first "Coefficient of
variation" header and then asserts the remaining column count.

### TY2000 is a defective file, and the aligner repairs it

SOI's TY2000 Table 1 publishes **30 contiguous rows** — the wholesale and
retail block, "Wholesale trade, durable goods" through "General merchandise
stores" — with the **last six columns rotated one position left**: the
prior-year-minimum-tax-credit value sits in the final column and everything
else one column early. `repair_rotated_block()` rotates them back, scoped to
this one vintage, and asserts the repair worked. Three independent
confirmations that the defect (and the fix) are real:

1. Under the published order those rows report tax after credits far **above**
   tax before credits, and net worth above total assets — both definitionally
   impossible. No other vintage 1998–2013 contains a single such row.
2. After rotating, the credits identity closes exactly: Retail trade's
   16,807,119 before credits − 689,114 credits = 16,118,005 after credits.
3. The rotated values are smooth against the neighbouring vintages — Retail
   trade tax after credits 15,464 → **16,118** → 16,137 ($ millions) across
   1999–2001, total assets 1,105,860 → **1,164,834** → 1,172,308.

### What verifies the panel

`check_sums()` requires sector detail + not-allocable rows to add to the
all-industries row for every year × item, which simultaneously guards the
sector list, the aggregate exclusions, and the first-occurrence rule — get any
of them wrong and the sums move by percent, not by rounding. Worst observed
relative gap across all 418 testable combinations: **2.5e-06** (2007 net
worth); the tolerance is 1e-04. Seams checked and smooth at 2003/04 (file
scheme), 2006/07 (item set) and 2013/14 (renumbering); the all-industries
return count rises 4.85M (1998) → 6.85M (2022).

## `aligned/table_01_cv.csv` — the same table's coefficients of variation

Same shape, same 9,410 cells, `unit = cv_pct`, built by the same code over a
different file map — so a CV joins onto its estimate on `(tax_year, industry,
item)`. Sampling variability for every cell of the sector panel.

### File map

| Years | File |
|---|---|
| 1998 | **no separate CV file** — CVs are columns 21–40 of `98co01nr.xls` |
| 1999–2003 | `{yy}co01cv.xls` (1999 uppercase `.XLS`) |
| 2004–2005 | `{yy}co01bccr.xls` — the `b` half of the split |
| 2006–2013 | `{yy}co01cv.xls` |
| 2014–2022 | `modern/table_01_cv/table_01_cv_{year}.xlsx` |

Column counts and item order mirror the estimates exactly in every era, so
`t1_items()` is reused unchanged. The block selection splits a sheet holding
both measures at the first column whose header carries the CV spanner, which
also makes a standalone CV file (spanner on column 1) work through the same
rule. **The TY2000 rotation does NOT apply to the CV file** — its
wholesale/retail block keeps the large prior-year-minimum-credit CV in the
first of the last six columns, exactly as 1999 and 2001 do — so the repair is
scoped to the estimates.

### Two published-file quirks the CV panel exposed

- **The 2001 CV file is paginated.** It prints columns 21–40 across four
  pages, each with its own title block, stub header and number row, carrying a
  different slice of industries. That is a *row* continuation, distinct from
  1996 Table 1's *column* continuation, and `find_numrows()` now tells them
  apart by whether the block's numbers repeat the first block's or continue
  past them (`kind = 'rows'` vs `'cols'`). Before the fix the file failed
  loudly on a header cell reaching the value parser — not silently truncated.
- **Footnote references in parentheses.** The percent tables write "(4)" where
  a CV is undefined — 161 such cells in TY2010 — which the money-table
  convention would read as −4. `clean_value(paren_negative = FALSE)` treats
  them as footnote flags for percent sheets; the money tables keep parentheses
  as negatives. Six cells in the TY2000 CV file are worse: the footnote reached
  the sheet as the *number* −4, indistinguishable by text. Those are caught by
  the sign rule below.

### What verifies the panel

- **Parallelism**: every `(tax_year, industry, item)` in the CV panel pairs 1:1
  with the estimates panel — 9,410 cells, no orphans either way.
- **Sign rule**: a CV may be negative only where its own estimate is negative
  (SOI carries the sign of the mean). Three cells qualify, all the negative net
  worth of the not-allocable residual in 2000/2001/2005. Any other negative CV
  is a footnote artifact and becomes NA with a `(4)` flag; the run fails if
  more than a handful appear. Two such cells exist (TY2000 manufacturing).
- **Cross-validation at 2013**, which publishes CVs twice: the standalone file
  against the inline block in the estimates sheet gives **4,096 of 4,097**
  numeric cells identical with NA patterns agreeing everywhere. The lone
  mismatch is SOI's own — "Support activities for mining", foreign-tax-credit
  CV, reads 8.0 in `13co01cv.xls` and 0.68 in `13co01ccr.xls`, both stored as
  numbers with every neighbouring cell agreeing. It is a minor industry, so it
  falls outside the sector panel; the aligner reads the standalone file, whose
  headers are clean (the inline block's stacked headers pick up wrap
  contamination — "Business net income receipts", "Net income goods sold").
- **1998**, the one year with no standalone CV file, is checked by continuity:
  its inline CVs track 1999 closely (all-industries number-of-returns CV 0.18
  vs 0.19, manufacturing 2.12 vs 2.13).

Observed CV range across the panel: −230.90 to 691.25. Large values are real —
SOI prints them for thin cells, e.g. net worth of the not-allocable rows — so
the range assertion is deliberately loose and about structure, not statistics.

## Next increments

- **Tables 5.1–5.4** (← old 6, 7, 12, 13): items × industry **columns**, so
  the sector list is matched against `col_label`/`col_group` instead of the
  stub. `col_group` gives the spanner path where the file records merges
  (all of the modern 5.x, most 2013-era `.xls`, nothing before ~2003); sector
  *total* columns are identifiable in every era because the spanner text sits
  in the sector's first column ("Mining Total").
- **1120S set and Tables 10/11/12** at sector level, per
  [alignment_plan.md](alignment_plan.md) Tier 2.
