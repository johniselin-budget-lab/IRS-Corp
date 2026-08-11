# Table 4 — Returns with Total Income Tax after Credits (non-1120S/REIT/RIC)

"Number of Returns and Selected Tax Items, by Size of Total Income Tax After
Credits." Covers active corporations **other than Forms 1120S, 1120-REIT, and
1120-RIC**. `align_table4.R` builds the harmonized 1994–2022 panel
(`aligned/table_4.csv` at the data destination).

## Where it lives by year

| Years | File (under the destination) | Format |
|---|---|---|
| 2014–2022 | `modern/table_04/table_04_{year}.xlsx` | xlsx |
| 2004–2013 | `archive/{year}/{yy}co22ccr.xls` | BIFF8 xls |
| 1998–2003 | `archive/{year}/{yy}co22nr.xls` | BIFF4 (1998–2002), BIFF8 (2003) |
| 1997 | `archive/1997/TABL22.XLS` | BIFF4 |
| 1996 | `archive/1996/CRTB22.XLS` | BIFF8 |
| 1995 | `archive/1995/CRTAB22.XLS` | BIFF4 |
| 1994 | `archive/1994/94CO22AC.XLS` | BIFF4 |

Before 2014 this was **Table 22** of the old Complete Report numbering; the
2014 renumbering to Table 4 is documented in SOI's own crosswalk
(`docs/table_crosswalk_2014.pdf`). The BIFF4 vintages cannot be read by
`readxl`/libxls — the aligner shells out to `read_biff4.py` (python3 + xlrd)
for them.

## The one big alignment gotcha: what "Total" means

- **1994–2013 (Table 22):** the table spans *all* active non-S/REIT/RIC
  corporations. "Total" (≈1.6–2.3M returns) includes returns with **zero**
  total income tax after credits, and there are explicit subtotal rows for
  returns with/without net income, with tax before credits, and **with tax
  after credits** (the last is what the size classes add to).
- **2014+ (Table 4):** the table covers only returns **with** total income
  tax after credits — its "Total" row (≈0.4–0.6M returns) is the old
  "Returns with total income tax after credits" subtotal, *not* the old
  "Total".

The aligner encodes this in `row_type`: the continuous 1994–2022 series is
`with_tax_after_credits` (+ the 15 `size_class` rows); `total_active`,
`with_net_income`, `without_net_income`, and `with_tax_before_credits` exist
for 1994–2013 only.

## Size classes

The 15 brackets are **identical across all 29 years** (in whole dollars,
while money amounts are in thousands): $1–6K, 6–10K, 10–15K, 15–20K, 20–25K,
25–50K, 50–75K, 75–100K, 100–250K, 250–500K, 500K–1M, 1–10M, 10–50M, 50–100M,
$100M or more. `class_lo` gives the lower bound in dollars.

## Columns (canonical `variable` names) by era

| variable | 94 | 95–05 | 06 | 07–13 | 14–22 | notes |
|---|---|---|---|---|---|---|
| `n_returns` | x | x | x | x | x | |
| `income_subject_to_tax` | x | x | x | x | x | |
| `tax_before_credits` | x | x | x | x | x | includes AMT and misc. taxes in pre-2014 vintages (see footnotes in the files); corporate AMT repealed by TCJA from 2018 |
| `income_tax` | x | x | x | x | x | labeled **"Regular tax"** in 1994–95, "Income tax" thereafter |
| `foreign_tax_credit` | x | x | x | x | x | |
| `us_possessions_tax_credit` | x | x | x | | | credit phased out (IRC §936 repeal) |
| `orphan_drug_credit` | x | | | | | 1994 only; folded into the general business credit from 1995 |
| `nonconv_fuel_credit` | x | x | | | | last published 2005 |
| `general_business_credit` | x | x | x | x | x | |
| `prior_year_min_tax_credit` | x | x | x | x | | dropped with the 2014 renumbering |
| `tax_after_credits` | x | x | x | x | x | |

Columns are matched positionally per era and each mapped column's header text
is verified against a keyword (`HEADER_CHECK`) — a layout change fails loudly.

## Value cleaning and flags

- Money amounts in **thousands of dollars** (`unit` column).
- Footnote references (`[8]` etc.) and thousands separators are stripped.
- `flag = 'd'`: disclosure-suppressed cell (value NA) — appears in the
  general business credit column in 2020–2022.
- `flag = '*'`: SOI "use with caution / based on few returns" marker (value
  kept).
- `flag = '-'`: published dash = none reported; recorded as value 0.
- 2017 and 2020 publish **unrounded weighted estimates** for the number of
  returns (e.g. Total 2017 = 505,906.319) — kept as published, do not be
  surprised by fractional return counts.
- Rows whose data cells are entirely empty are dropped: they are label
  wrap-arounds or footnote lines (after footnote-marker stripping, e.g.
  "[17] Returns without net income include …" starts like a row label).

## Consistency checks built into the aligner

- 15 size classes and exactly one of each subtotal row per year.
- Size classes must sum to the `with_tax_after_credits` subtotal within
  0.5% (skipped for year × variable cells with any flagged value).

## Comparability cautions for the panel

- Definitional drift inside `tax_before_credits` / `income_tax` (AMT and
  various add-on taxes enter and leave; see each vintage's footnotes and the
  Explanation of Terms PDFs in `archive/{year}/`).
- TCJA (2018): 21% flat rate, corporate AMT repeal — level breaks in the tax
  series around 2017–2018 are real policy, not alignment error.
- Nominal dollars, and the size-class bounds are nominal too — bracket drift
  over 29 years is substantial.
