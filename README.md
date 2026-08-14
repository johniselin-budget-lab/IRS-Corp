# IRS-Corp

Downloader for an organized mirror of the IRS SOI **Corporation Complete
Report (Publication 16)** basic tables, plus aligned cross-year panels:
1994–2022 for Tables 4, 2.1, 2.2, and 3.1, 1998–2022 for Tables 1 (with its
coefficients of variation) and 5.1–5.4 at NAICS sector level, 2004/2006–2022
for the whole Form 1120S set (6.1, 6.2, 7, 8 by industry; 3.2 and 9 by class),
and 2014–2022 generic panels for every basic table (see `aligned/` below):

- 2014+ (xlsx per table):
  https://www.irs.gov/statistics/soi-tax-stats-corporation-income-tax-returns-complete-report-publication-16
- 1994–2013 (one zip per tax year):
  https://www.irs.gov/statistics/soi-tax-stats-corporation-complete-report-1994-to-2013

This repo holds the **code only** — data is downloaded on demand, either into
the repo's own (gitignored) `data/` folder or to a separate location of your
choosing. All source files are U.S. federal government works (public domain).
Files are stored **as published** (xlsx / legacy xls / WK1+FMT companions /
documentation PDFs); no transformation happens at download time.

## Usage

```bash
Rscript download_irs_corp.R                        # -> ./data, years 1994-2022
Rscript download_irs_corp.R 2014 2023              # custom year range
Rscript download_irs_corp.R --dest /path/to/store  # separate destination

Rscript align_table4.R --dest /path/to/store       # build aligned/table_4.csv
Rscript align_industry.R --dest /path/to/store     # industry panels (1, 1 CV, 5.1-5.4, 6.1, 6.2, 7, 8)
Rscript align_tables.R --dest /path/to/store       # modern + class panels (2.1, 2.2, 3.1, 3.2, 9)
```

Budget Lab internal users: the canonical shared destination (already
populated) is documented internally — pass it via `--dest`.

The downloader is idempotent (existing files and already-extracted archive
years are skipped), tolerates unpublished files (HTTP 404s skipped with a
message), and rewrites a checksummed `manifest.csv` (path, source URL, year,
bytes, md5, retrieval date) at the destination each run.

The aligners additionally need **python3 with xlrd**
(`python3 -m pip install --user xlrd`) because the 1994–2002 vintages
(except 1996) are BIFF4 Excel files that R's `readxl` cannot open
(`read_biff4.py` bridges them), and because the industry-spanner
hierarchy in the column-industry tables is recovered from merged-cell
ranges (`read_xls_merges.py`, for the 2003+ .xls vintages). Shared
parsing machinery lives in `alignment_helpers.R`.

## Data layout (under the destination)

```
modern/table_{id}/  table_{id}_{year}.xlsx  2014+ basic tables, one folder per
                                            table; {id} is the published table
                                            number, zero-padded so listings
                                            sort in publication order
                                            (table_01, table_01_cv, table_02_1,
                                            ... table_02_4a, ... table_04, ...
                                            table_14)
archive/{year}/     as-published contents of that year's zip (1994-2013):
                    ~25 .xls tables per year under the OLD table numbering,
                    documentation/section PDFs, and for the mid-1990s
                    legacy .WK1/.FMT companion files
docs/               table_crosswalk_2014.pdf   SOI's old->new table-number map
    pub16/          p16--{rev}.pdf   full Pub 16 PDFs, named by revision year
                                     as published (each covers a tax year
                                     ~3 years earlier)
aligned/            table_4.csv      harmonized Table 4 panel, 1994-2022
                                     (written by align_table4.R)
                    table_02_1.csv   class panels (align_tables.R): items x
                    table_02_2.csv   size classes for Tables 2.1 (old 2), 2.2
                    table_03_1.csv   (old 3) and 3.1 (old 5), 1994-2022; then
                    table_03_2.csv   Form 1120S by receipt size (old 1120S 4)
                    table_09.csv     and by number of shareholders (old 1120S
                                     6), both 2004-2022
                    table_01.csv     industry panels at NAICS SECTOR level,
                    table_01_cv.csv  1998-2022 (align_industry.R): Table 1
                    table_05_1.csv   and its coefficients of variation, then
                    table_05_2.csv   the full balance-sheet/income-statement
                    table_05_3.csv   stub by sector for each of the four 5.x
                    table_05_4.csv   universes (all active corporations;
                                     returns with net income; each again
                                     excluding Forms 1120S/1120-REIT/1120-RIC),
                    table_06_1.csv   then the Form 1120S industry tables --
                    table_06_2.csv   balance sheet for active corporations and
                    table_07.csv     for returns with net income (2006-2022),
                    table_08.csv     income (2004-2022) and rental real estate
                                     (2004-2022). All ten share one schema and
                                     join on (tax_year, industry)
    modern/         {table_id}.csv   every basic table 2014-2022, generic
                                     long format keyed on published labels,
                                     with industry-hierarchy columns
                                     (row_indent, col_group)
                    _coverage.csv    label x years-present (drift detector)
manifest.csv        path, source url, year, bytes, md5, retrieval date
```

## Coverage and source-naming quirks

| Source | Years | SOI naming |
|---|---|---|
| Modern basic tables | 2014–2022 | `{yy}co{code}ccr.xlsx`; codes `01`, `01cv`, `21`, `21a`, ..., `04`, ..., `62` map to published table numbers (see `MODERN_TABLES` in the downloader). Table 14 starts 2015. Table 13 is Table 13.1 (non-S/REIT/RIC only) through 2016 under the same filename. |
| Archive zips | 1994–2013 | `{yy}coalcr.zip` (1994–2009), `{yy}coalccr.zip` (2010–2013). Table filenames inside change scheme repeatedly — e.g. the same table is `94CO22AC.XLS`, `CRTAB22.XLS` (95), `CRTB22.XLS` (96), `TABL22.XLS` (97), `{yy}co22nr.xls` (98–03), `{yy}co22ccr.xls` (04–13). |
| Pub 16 PDFs | rev. 2019+ | `irs-prior/p16--{rev}.pdf`, revision-year names (no 2024 revision exists). The 1994–2013 report PDFs ship inside the zips. |

**Table numbering changed in 2014.** The pre-2014 Complete Report numbered
its tables 1–27 (plus a separate 1120S table set); SOI's crosswalk
(`docs/table_crosswalk_2014.pdf`) maps them to the modern numbers. Modern
**Table 4 = old Table 22**, modern 5.1 = old 6, etc. Several old tables
(4, 8, 9, 11, 14–19, 21, 23–25, 27) have **no modern successor**, and the
1994–2002 files are legacy BIFF4 Excel (see `read_biff4.py`).

## Notes on the data

- [notes/table4.md](notes/table4.md) — Table 4 / old Table 22 (the aligned
  test-case table): file map by year, the "Total"-row semantics change at
  the 2014 renumbering, column availability by era, flags/suppression,
  fractional return counts in 2017/2020, comparability cautions.
- [notes/modern_tables.md](notes/modern_tables.md) — the rest of the tables:
  modern-panel label stability (NAICS drift, the Table 13 definition break),
  deep-panel mechanics (class-bound units, bracket changes, item aliases and
  the seam verification), and the roadmap for old-table pairs not yet
  deep-aligned.
- [notes/industry_tables.md](notes/industry_tables.md) — the industry-dimension
  panels: why they are aligned at sector level and start in 1998, why rows are
  matched by name rather than stub indentation, how the sector's own column is
  found once the header geometry moves, the per-era item sets, the file-naming
  traps, and the published defects the aligner repairs (TY2000's shifted
  column block, and the four files typeset without minus signs).
- [notes/alignment_plan.md](notes/alignment_plan.md) — the standing plan:
  what is aligned, what remains (tiered by blocker), recommended order, and
  a proposal to mirror/align the SOI partnership statistics as a sibling
  repo.

When SOI publishes a new year, extend the range:
`Rscript download_irs_corp.R --dest <store> 1994 2023`.
