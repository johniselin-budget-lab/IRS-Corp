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

## `aligned/table_05_{1,2,3,4}.csv` — the 5.x family at sector level, 1998–2022

Same schema as `table_01.csv`, so every panel joins on `(tax_year, industry)`
and they all share one set of industry names. Where Table 1 puts industries in
its rows and a short headline item list in its columns, the 5.x family
transposes it — the full balance-sheet and income-statement stub in the rows,
industries across the columns — so `align_industry.R` matches the sector list
against the column headers instead of the stub.

The four differ only in which returns they cover, which is why one spec list
drives all of them:

| Panel | Old table | Universe | Cells | Items (all 25 years) |
|---|---|---|---|---|
| `table_05_1.csv` | 6 | all active corporations | 38,746 | 85 (63) |
| `table_05_2.csv` | 7 | returns with net income | 38,606 | 87 (60) |
| `table_05_3.csv` | 12 | active corporations other than Forms 1120S, 1120-REIT, 1120-RIC | 38,606 | 88 (60) |
| `table_05_4.csv` | 13 | returns with net income, same exclusion | 38,606 | 87 (60) |

Each is 22 industries × 74–79 items in 1998–2013 and 20 × 68–69 from 2014.
Both cuts carry over unchanged: sector level (the ~240 minor-industry columns
drift at every NAICS revision) and a 1998 start (1994–97 are SIC).

**Archive filenames carry a per-table suffix** that changes at the 2004 switch
to `ccr`: old 6 and 7 are `{yy}co06nr.xls` / `{yy}co07nr.xls` before it, old 12
and 13 are `{yy}co12mi.xls` / `{yy}co13mi.xls` (TY1999 ships both UPPERCASE).
The exact-match lookup also keeps the 1120S companions `{yy}co06s.xls` /
`{yy}co07s.xls` (published 2006–2013) out of the way — a different population,
on the Tier 2 roadmap.

Reading the series in one line: 5.3's return count *falls* from 2.25M (1998)
to 1.56M (2022) while 5.1's rises from 4.85M to 6.85M — the S-corporation
share of corporate returns growing, which is what makes the 5.1/5.3 split
worth carrying.

### Items are text labels, and reuse the 2.x alias set

Unlike Table 1's positional columns, the 5.x rows are the same balance-sheet /
income-statement stub published in Tables 2, 3 and 5, so they harmonize
through the shared `ITEM_ALIASES` in `alignment_helpers.R` (moved there from
`align_tables.R` when these panels started using it). Taking 5.1 as the
example — 85 items across the span, **63 in all 25 years** — what does not
span it:

- `net worth, total`, `dividends`, `tax-exempt interest` — 2014 onwards only;
  the pre-2014 table has no net-worth line and splits dividends into domestic
  and foreign.
- the credit and special-tax detail (`foreign tax credit`, `alternative
  minimum tax`, `personal holding company tax`, …) — pre-2014 only, the same
  thinning Table 1 shows.
- `salaries and wages` is missing from **TY2001 only** — SOI's file genuinely
  omits the line, going straight from cost of goods sold to compensation of
  officers.

Two label traps, both handled by machinery rather than by ad-hoc aliases:

- **Wrapped stubs.** SOI breaks a long item over two stub lines and puts the
  data on the second, so `extract_sheet` reads the first as a section header
  ("Mortgages, notes, and bonds payable in less" + "than one year"). Every
  section header these tables produce — all four, all 25 vintages — is such a
  wrap, so the row directly below one is glued back onto it, which reproduces
  the published label exactly and lets the existing aliases do the rest.
- **Footnote lists.** TY2018 writes "Total deductions [1,2]";
  `normalize_label` now strips comma-separated footnote refs, not just single
  ones.

### Sector columns: three passes, because the header geometry moves

The sector's own column is its block **total**. Finding it takes three rules,
each for a era the one before cannot read:

1. **The column names itself** — the spanner stacks onto its own "Total"
   ("Mining", "Construction Total"). Covers 1999, 2001–2006 and 2014–2022.
   Two things come off the stacked header first: the "-- continued" spanner a
   wide vintage repeats over each later printed panel, and the doubled phrase
   the modern files leave behind ("Coal mining Coal mining").
2. **The enclosing aggregate stacks on top** — from 2007 the wholesale column
   is headed "Wholesale and retail trade Wholesale trade Total". Only that
   exact composition counts: matching a bare suffix would hand Retail trade
   the *aggregate's* column, whose key ends in the same two words.
3. **The spanner is centred, not anchored** — TY1998 and TY2000 place the
   block's name over the middle of its columns, so it lands on a minor
   industry and the sector's own column is headed bare "Total"
   ("Agriculture, forestry, fishing, and hunting" sits over "Agricultural
   production"; "Manufacturing" two columns before its own total). Centred
   text still falls inside its block, so the sector's column is the last
   unclaimed block total at or before the leftmost column its name opens.

Aggregates are excluded by omission, exactly as in Table 1: "Wholesale and
retail trade" has a column of its own and is not in `SECTORS`.

### Four published files carry no minus signs

Some SOI files were typeset with minus signs stripped from part of the body,
which shows as a count of negative cells far below what the vintages either
side carry. Four are affected, and they are the *only* four across the whole
1998–2022 span of these six panels:

| File | Table, tax year | Negative cells | Neighbouring vintages |
|---|---|---|---|
| `07co01ccr.xls` | 1, TY2007 | — | net worth row only |
| `07co06ccr.xls` | 6 → 5.1, TY2007 | 6 | 46 (TY2006), 68 (TY2008) |
| `07co07ccr.xls` | 7 → 5.2, TY2007 | — | same two items as Table 6 |
| `08co13ccr.xls` | 13 → 5.4, **TY2008** | 6 | 24 (TY2007), 17 (TY2009) |

Table 12 → 5.3 is clean throughout, and so is every other vintage.

The affected cells are pinned down by identities, not inferred. Every entry in
`UNSIGNED_CELLS` is both (a) the **only** set of cells whose restoration makes
that item's sector detail add to its total — searched over all subsets up to
six industries, to the nearest thousand — and (b) corroborated independently:

- Table 5.1's equity build-up (capital stock + additional paid-in capital +
  retained earnings appropriated + unappropriated − cost of treasury stock)
  reproduces Table 1's independently published **net worth** for every
  industry in TY2006 and TY2008. In TY2007 it overshoots for six industries,
  each time by *exactly twice* that industry's retained earnings,
  unappropriated. Restoring those six takes the sector-detail gap on that item
  from **15.4% to 9e-10**.
- The net short-term capital gain item names the **same two industries** in
  Tables 6 and 7 independently (4.6% → 1.1e-08, and 4.8% → exactly zero), and
  TY2007 is the one year in the span where either is published positive.
- The two not-allocable residual columns are stripped again on `total
  receipts less total deductions` and `net income (less deficit)`: flipping
  both moves each sum by 64,726 against gaps of 64,725 and 64,727, where every
  neighbouring vintage closes to a single unit.
- **Table 1 is stripped too** — its net worth row, for the same two residuals.
  That accounts for the whole of the 2.5e-06 gap that was previously the worst
  in that panel; restoring the two closes it to 3e-11 and drops the panel's
  worst gap to 2.36e-06 (TY2001 U.S. possessions tax credit, three units of
  rounding on $1.27 billion).
- Table 13's three TY2008 industries are negative in TY2006, TY2007 and
  TY2009 and positive only in TY2008; restored, the sum closes to 2.9e-10.

Only the sign is wrong — every magnitude is confirmed by the identity it sits
in — so the cells are restored rather than dropped, and every panel asserts
afterwards that its sums close.

### What verifies the panels

- **Sector sums**: detail + residuals = all-industries for every year × item —
  1,706 / 1,570 / 1,495 / 1,404 combinations across 5.1–5.4, worst relative
  gap **2.36e-06** in the first three and 4.95e-06 in 5.4 (TY2011 return
  counts, about 17 returns in 3.5 million). A gap has to clear both a relative
  and an absolute floor: one unit of the published rounding is 1e-4 of a small
  item like TY1999 recapture taxes ($9.8 million), which would otherwise fail
  on nothing at all.
- **Against Table 1**: Table 1 and the 5.x reach the same quantities by
  unrelated routes — row labels in one, column headers in the other. 5.1
  shares seven items with Table 1's own universe (**3,596** cells, worst
  4.28e-05) and 5.2 matches Table 1's two "with net income" columns (**1,038**
  cells, worst 4.91e-06). Both worst cases are Table 1's fractional return
  counts (2014 utilities, 6,695.71 against 6,696).
- **Nesting**: each universe is a subset of the ones above it, so its return
  count can never exceed theirs — checked for 5.2 ⊆ 5.1, 5.3 ⊆ 5.1, 5.4 ⊆ 5.2
  and 5.4 ⊆ 5.3 over ~530 industry-years each. This is the only check that
  reaches 5.3 and 5.4, which have no Table 1 counterpart, and a mis-assigned
  sector column would show as one industry's count jumping above its superset.
- **Seams** smooth at 2003/04, 2006/07 and 2013/14; 5.1's all-industries total
  assets run $37.3T (1998) → $143.3T (2022), and `additional paid-in capital`
  reproduces the `table_02_1` series year for year.

## Next increments

- **1120S set and Tables 10/11/12** at sector level, per
  [alignment_plan.md](alignment_plan.md) Tier 2. Tables 6.1/6.2 and 7 are the
  1120S counterparts of the 5.x and should take the same spec-list treatment;
  their archive files (`{yy}co06s.xls`, `{yy}co07s.xls`) exist only for
  2006–2013, so they buy a shorter history.
- **Minor-industry concordance**, the one remaining blocker on all of these.
