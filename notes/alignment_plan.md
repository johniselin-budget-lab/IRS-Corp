# Alignment plan: remaining work on cross-year corporate panels

Status as of 2026-08. What is already aligned, what remains, and in what
order to do it. Companion to [table4.md](table4.md) (the Table 4 test case)
and [modern_tables.md](modern_tables.md) (engine mechanics, deep-panel
gotchas, alias curation method).

Sources: [Pub 16 modern page (2014+)][pub16] · [1994–2013 zip archive
page][archive] · [SOI's 2014 table-number crosswalk][xwalk] (mirrored at
`docs/table_crosswalk_2014.pdf` in the data store).

[pub16]: https://www.irs.gov/statistics/soi-tax-stats-corporation-income-tax-returns-complete-report-publication-16
[archive]: https://www.irs.gov/statistics/soi-tax-stats-corporation-complete-report-1994-to-2013
[xwalk]: https://www.irs.gov/pub/irs-soi/14cotablecrosswalkccr.pdf
[srcbook]: https://www.irs.gov/statistics/soi-tax-stats-corporation-source-book-data-file

## Done

| Panel (at the data store) | Years | Source tables |
|---|---|---|
| `aligned/table_4.csv` | 1994–2022 | Table 4 ← old Table 22 ([table4.md](table4.md)) |
| `aligned/table_02_1.csv` | 1994–2022 | Table 2.1 ← old Table 2 (balance sheet by asset size) |
| `aligned/table_02_2.csv` | 1994–2022 | Table 2.2 ← old Table 3 (net-income returns by asset size) |
| `aligned/table_03_1.csv` | 1994–2022 | Table 3.1 ← old Table 5, All-Industries block (by receipt size) |
| `aligned/modern/{table_id}.csv`, all 26 tables | 2014–2022 | generic long panels + `_coverage.csv` label-drift report |
| `aligned/table_01.csv` | 1998–2022 | Table 1 ← old Table 1, **sector level** ([industry_tables.md](industry_tables.md)) |
| `aligned/table_01_cv.csv` | 1998–2022 | Table 1 CV ← old Table 1 CV, same shape |

Everything alignable by pure text-label matching is done, and the first
industry panel (Table 1 at sector level) is built. The remaining work is
tiered by what blocks it.

## Tier 1 — industry tables, NAICS era (1998 → present). The big prize.

The item dimension of these tables is already solved (the balance-sheet /
income-statement stubs reuse `ITEM_ALIASES` from the 2.x panels); the
blocker is the **industry dimension**, which follows NAICS with revisions in
2002, 2007, 2012, and 2017. The 2017 revision is visible in
`aligned/modern/_coverage.csv` (~66 of 243 minor-industry columns drift
mid-panel in Table 5.1).

| Modern table | Old table (1994–2013 zips) | Orientation | Notes |
|---|---|---|---|
| [Table 1][pub16] (`{yy}co01ccr.xlsx`) | old 1 (`{yy}co01ccr.xls` 2004+, `{yy}co01nr.xls` 98–03) | industry rows × item cols | **DONE at sector level** → `aligned/table_01.csv` |
| [Table 1 CV][pub16] (`{yy}co01cvccr.xlsx`) | old 1cv (`{yy}co01cv.xls`) | same | **DONE at sector level** → `aligned/table_01_cv.csv` |
| [Tables 5.1–5.4][pub16] (`{yy}co51–54ccr.xlsx`) | old 6, 7, 12, 13 | items × industry cols | old files: item stubs ≈ Table 2 alias set |

Two levels of ambition:

1. **Sector level (19 NAICS sectors)** — labels stable since 1998; mechanical
   with the existing engine. Deliverable: industry × item panels 1998–2022.
   *Done for Table 1* — the recipe, the pitfalls, and the verification are
   written up in [industry_tables.md](industry_tables.md). Headlines for the
   tables that follow: match sector **names**, never stub indentation (SOI
   drops indentation entirely from 2017); exclude the 1998–99 supersectors and
   "Wholesale and retail trade" or the detail double counts; and use the
   sector-sum-vs-total check as the guard on every such choice.
2. **Minor-industry level** — needs a curated per-revision concordance
   (renames bridgeable; splits only by aggregating). Only worth it if a
   downstream use needs sub-sector detail.

Engine prerequisite (shared by everything below) — **done 2026-08**:
`extract_sheet` handles stacked/repeated panels (1996 Table 1's rows-below
continuation and 1996 Table 2's side-by-side panels) and emits the industry
hierarchy: `row_indent` (stub leading spaces, all eras) and `col_group`
(merged-cell spanners; empty pre-2003 where files carry no merge records).
Mechanics and per-era caveats in
[modern_tables.md](modern_tables.md#industry-dimension-machinery-the-tier-1-engine-prerequisite-done-2026-08).
Remaining spec-level wrinkle for Table 1: 2004+ splits its two column
panels into `{yy}co01accr.xls` / `{yy}co01bccr.xls` — the file map must
carry both parts.

## Tier 2 — shallower history, engine-ready

**1120S family.** The `{yy}co0Xs.xls` files exist in the archive zips only
for **2004 and 2006–2013** (2005 absent; 2008 has just 2 of 7), so backward
extension buys ~9 patchy years:

| Modern | Old 1120S table | Classifier | Difficulty |
|---|---|---|---|
| [Table 7][pub16] | 1120S table 1 | major industry | industry dimension (Tier 1 machinery) |
| [Table 8][pub16] | 1120S table 5 | sector × asset size | label-stable, easy |
| [Table 9][pub16] | 1120S table 6 | number of shareholders | label-stable, easy |
| [Table 3.2][pub16] | 1120S table 4 | receipt size | size classes — same as 3.1 treatment |
| [Tables 6.1/6.2][pub16] | 1120S tables 7/8 | major industry | industry dimension |

**Sector-column tables.** [Table 10][pub16] ← old 10 (1120-F), [Table
11][pub16] ← old 20 (dividends), [Table 12][pub16] ← old 26 (COGS): modest
tables, sector columns — cheap at sector level alongside Tier 1.

## Tier 3 — blocked on data or a scoping decision

- **Tables 2.4 / 2.4A** ← [Corporation Source Book][srcbook] Table 3. The
  Source Book is a separate SOI product not in this repo's archive;
  extending these panels past 2014 means mirroring a new publication first.
  Decision needed on whether it's worth carrying.
- **Pre-1998 industry data**: 1994–1997 use **SIC**, not NAICS (verified in
  `archive/1994/94CO01MI.XLS` — "Agricultural services", metal-mining
  detail, etc.). Only a coarse division-level bridge is defensible;
  recommendation: cut the industry panels at 1998 and document it.
- **Old-only tables** (old 4, 8, 9, 11, 14–19, 21, 23–25, 27 — no modern
  successor per the [crosswalk][xwalk]): could become closed 1994–2013
  panels if a use case appears. Skip until then.
- **No pre-2014 counterpart exists** for 2.1A, 2.3, 2.4A, 3.3, 13, 14 —
  their modern panels are already the full history.

## Tier 4 — polish on existing panels

- Canonicalize the 2.x asset-class column labels inside the *generic*
  modern panels (cosmetic — the deep panels already canonicalize them).
- Add class-sum-vs-total checks to the deep panels (Table 4's aligner has
  them; `align_tables.R` currently checks only the returns-count total).
  Mind the old Table 5 overlapping "Under $100,000" subtotal column.
- Table 13 stays two series (13.1 through 2016, 13 from 2017) — documented,
  nothing to fix.
- Rerun `download_irs_corp.R` + both aligners when SOI publishes TY2023
  Pub 16 (not out as of 2026-08).

## Proposed extension: partnership statistics (Form 1065)

Proposal to mirror and align the [SOI partnership statistical
tables][pship] the same way — surveyed 2026-08. Partnerships are a separate
legal population, so the cleanest home is a **sibling repo (`IRS-Pship`)
with its own shared store**, built from this repo's template and reusing
the `alignment_helpers.R` engine; the alternative (a `partnership/` family
inside IRS-Corp) muddies what "Corp" means. Four sub-pages to carry:

[pship]: https://www.irs.gov/statistics/soi-tax-stats-partnership-statistics
[pship-ind]: https://www.irs.gov/statistics/soi-tax-stats-partnership-statistics-by-sector-or-industry
[pship-ent]: https://www.irs.gov/statistics/soi-tax-stats-partnership-statistics-by-entity-type
[pship-ta]: https://www.irs.gov/statistics/soi-tax-stats-partnership-data-by-size-of-total-assets
[pship-hist]: https://www.irs.gov/statistics/soi-tax-stats-partnership-returns-historical-and-projected-data

| Sub-page | Files | Coverage & naming | Alignment prospect |
|---|---|---|---|
| [By sector or industry][pship-ind] | ~220 (Tables 1–7, 23, 10) | 1993–2023; suffixed names pre-2004 (`{yy}pa01ig.xls`…), plain `{yy}pa01.xls` 2004–14, `.xlsx` 2015+ | industry dimension → same NAICS tiers as the corporate Tier 1 (SIC pre-1998); item stubs need their own alias set |
| [By entity type][pship-ent] | ~24 (Table 8; 9a–c new in 2023) | pa08: 2003–2023 continuously | **easiest win** — one table, stable entity-type columns (general/limited/LLC/LLP), label matching only |
| [By size of total assets][pship-ta] | ~180 (Tables 15–25) | mostly 2003/2005–2023 (`{yy}pa15ta.xls` 2003–04, plain 2005–14, `.xlsx` 2015+); pa18/22/25 appear to stop at 2014 | size-class columns → the 2.x deep-panel recipe applies directly (class parsing + item aliases) |
| [Historical and projected][pship-hist] | ~8 | small: `histab*` historical tables (2020 vintage) + a few 1993–97 strays | mirror as documentation; long historical series may substitute for pre-1993 alignment work |

Notes from the survey:

- The 2004–2014 `.xls` → 2015+ `.xlsx` switch is a format seam mid-series
  (unlike the corporate tables, which stayed `.xls` in the archive era and
  jumped to `.xlsx` at the 2014 renumbering). No BIFF4 sighted, but the
  1993–2003 vintages should be format-checked before promising `readxl`
  reads them.
- Table numbering appears **stable across the whole span** (pa01 is Table 1
  throughout) — no crosswalk problem like the corporate 2014 renumbering,
  just suffix drift before 2004.
- TY2023 is already published for most families — fresher than Pub 16
  (TY2022).
- Suggested order within the proposal: downloader + store first (all four
  sub-pages, as-published); then align pa08 (entity type) as the Table-4-style
  test case; then the by-asset-size set; industry tables last, sharing
  whatever NAICS concordance the corporate Tier 1 builds.

## Recommended order

1. ~~**Table 1 at sector level, 1998–2022**~~ — **done 2026-08**
   (`aligned/table_01.csv`, [industry_tables.md](industry_tables.md)). As
   intended, it forced the engine extension and established the sector recipe
   every later step reuses. It also bought a new file: `align_industry.R`,
   where the industry machinery (sector list, aliases, SIC cutoff) lives.
2. ~~**Table 1 CV, 1998–2022**~~ — **done 2026-08**
   (`aligned/table_01_cv.csv`). Same spec, different file map, `unit = cv_pct`;
   it also bought two engine fixes every later table inherits — paginated
   sheets (`find_numrows` kind `'rows'`) and parenthesised footnote references
   in percent tables (`clean_value(paren_negative = FALSE)`).
3. **Table 5.1 sector-level** (all-corporation balance sheet by industry) —
   reuses the 2.x item aliases; sectors are matched on the COLUMN dimension
   there, using `col_group` where the vintage records merged cells.
4. **1120S set** (2004/2006–2022) and Tables 10/11/12 at sector level.
5. **Minor-industry concordance** only when a downstream consumer actually
   needs sub-sector detail.
6. **Partnership repo** (proposal above) can start any time — the
   downloader + entity-type and asset-size panels don't depend on the
   corporate tiers; its industry tables should wait for whatever NAICS
   concordance step 1/5 produce.

Each step follows the established recipe: add a spec (per-era file map + the
label/positional mapping) to `align_tables.R` for size-class panels or
`align_industry.R` for industry panels, run, curate labels from the coverage
report, and verify at the era seams — plus a detail-adds-to-total check —
before adopting any merge.
