#!/usr/bin/env Rscript
#------------------------------------------------------------------------------
# align_industry.R
#
# Cross-year panels for the INDUSTRY-dimension tables of the Corporation
# Complete Report -- the tables whose classifier is an industry rather than a
# size class, and which therefore cannot be aligned by label matching alone
# (see notes/alignment_plan.md, Tier 1). Kept separate from align_tables.R
# because the machinery below -- the canonical sector list, the per-era sector
# label aliases, the SIC cutoff -- is shared by the industry tables and unused
# by the size-class panels there. Parsing itself is shared: both scripts use
# extract_sheet() and ITEM_ALIASES from alignment_helpers.R.
#
# Builds, all at NAICS SECTOR level:
#   aligned/table_01.csv      Table 1                                1998-2022
#   aligned/table_01_cv.csv   its coefficients of variation          1998-2022
#   aligned/table_05_1.csv    all active corporations                1998-2022
#   aligned/table_05_2.csv    returns with net income                1998-2022
#   aligned/table_05_3.csv    active corporations other than Forms
#                             1120S, 1120-REIT and 1120-RIC          1998-2022
#   aligned/table_05_4.csv    the same exclusion on returns with
#                             net income                             1998-2022
#   aligned/table_06_1.csv    Form 1120S, active -- balance sheet    2006-2022
#   aligned/table_06_2.csv    Form 1120S, net income -- balance sheet 2006-2022
#   aligned/table_07.csv      Form 1120S, active -- income           2004-2022
#   aligned/table_08.csv      Form 1120S, rental real estate         2004-2022
#     tax_year, row_type (all_industries | sector | not_allocable),
#     industry, item, value, flag, unit
#   Every panel shares that schema and the same canonical industry names, so
#   they join on (tax_year, industry) -- and the two Table 1 panels, built by
#   the same code over a different file map, join cell for cell on
#   (tax_year, industry, item) so a CV sits beside its estimate.
#
# Table 1 carries the industries in its ROWS and a short list of headline
# items in its columns; the 5.x and 1120S families transpose that -- the item
# stub in the rows, industries across the columns -- so the two halves of this
# script differ mainly in which dimension the sector list is matched against.
# What they share is INDUSTRIES below.
#
# WHY SECTOR LEVEL: minor-industry labels drift with every NAICS revision
# (2002, 2007, 2012, 2017), which needs a per-revision concordance; the 19
# SECTOR labels are stable across the whole span. WHY 1998: 1994-97 are
# SIC-coded, and only a coarse division-level bridge would be defensible.
# Both cuts are deliberate -- see notes/industry_tables.md.
#
# Sector selection is by canonical NAME, never by position or by the published
# hierarchy markers: stub indentation is unusable as a level marker (SOI wraps
# sectors in supersectors in 1998-99, indents Utilities differently from its
# siblings, and drops stub indentation entirely from 2017 on), and merged-cell
# spanners do not exist before 2003. Every year must yield all 19 sectors or
# the run fails.
#
# Usage:
#   Rscript align_industry.R [--dest /path/to/store]
#------------------------------------------------------------------------------

#-----------------
# Parse arguments
#-----------------

args = commandArgs(trailingOnly = TRUE)

script_dir = dirname(sub('--file=', '', grep('--file=', commandArgs(), value = TRUE)[1]))
if (is.na(script_dir) || script_dir == '') script_dir = '.'

source(file.path(script_dir, 'alignment_helpers.R'))

dest = file.path(script_dir, 'data')
if (length(args) > 0 && args[1] == '--dest') {
  if (length(args) < 2) stop('--dest requires a path')
  dest = args[2]
}

# NAICS starts in 1998 and Pub 16 currently ends at TY2022
INDUSTRY_YEARS = 1998:2022

#=============================================================================
# The industry dimension, shared by every panel below
#=============================================================================

# The 19 NAICS sectors SOI publishes, in published order, under their modern
# labels. Aggregates that also sit at sector level -- the 1998-99 supersectors
# ("Goods production", ...) and "Wholesale and retail trade" (= wholesale +
# retail + their not-allocable residual) -- are deliberately NOT here: keeping
# them would double count.
SECTORS = c(
  'agriculture, forestry, fishing and hunting', 'mining', 'utilities',
  'construction', 'manufacturing', 'wholesale trade', 'retail trade',
  'transportation and warehousing', 'information', 'finance and insurance',
  'real estate and rental and leasing',
  'professional, scientific, and technical services',
  'management of companies (holding companies)',
  'administrative and support and waste management and remediation services',
  'educational services', 'health care and social assistance',
  'arts, entertainment, and recreation', 'accommodation and food services',
  'other services')

ALL_INDUSTRIES = 'total returns of active corporations'

# Residual rows/columns, published 1998-2013 only: returns SOI could not
# assign to a sector. Kept (as row_type 'not_allocable') so that sectors +
# residuals reconcile against the all-industries total in those years; the
# modern tables have no such rows.
NOT_ALLOCABLE = c('wholesale and retail trade not allocable', 'not allocable')

INDUSTRIES = c(ALL_INDUSTRIES, SECTORS, NOT_ALLOCABLE)

# The one aggregate SOI nests two of the sectors inside. It gets a row of its
# own in Table 1 and a column of its own in Table 5.1, both excluded above --
# but its name also stacks on top of the two sectors it encloses, which the
# column search below has to read through.
AGGREGATES = 'wholesale and retail trade'

# Published variant -> canonical, keyed on the match key below. Curated from
# the per-year stub and header surveys.
#   * the administrative sector's long name wraps over TWO stub lines in
#     Table 1 1998-2006, and because the first line carries no data,
#     extract_sheet treats it as a section header and the sector's data lands
#     on the second line, "and remediation services";
#   * Table 5.1 heads the all-industries column "All industries" where Table 1
#     labels the same universe "Total returns of active corporations";
#   * TY1998 Table 6 misspells Accommodation.
INDUSTRY_ALIASES = c(
  'and remediation services' =
    'administrative and support and waste management and remediation services',
  'wholesale and retail not allocable' =
    'wholesale and retail trade not allocable',
  'all industries' = ALL_INDUSTRIES,
  'accomodation and food services' = 'accommodation and food services'
)

# Comparison key for an industry label. Ampersands are spelled out (the
# 1998-99 Table 1 vintages write "Agriculture, forestry, fishing & hunting")
# and punctuation is dropped, because SOI's serial comma wanders between
# tables -- Table 1 heads the sector "fishing and hunting", Table 5.1
# "fishing, and hunting". normalize_label() has already stripped footnote
# refs and dot leaders.
match_key = function(label) {
  k = tolower(label)
  k = gsub('&', ' and ', k)
  k = gsub("[[:punct:]]", ' ', k)
  trimws(gsub('\\s+', ' ', k))
}

INDUSTRY_MATCH = match_key(INDUSTRIES)

# A published label -> the canonical industry name it denotes, or NA for
# everything we do not keep (minor industries, supersectors, the wholesale and
# retail trade aggregate). Returning the canonical string rather than the
# published one is what makes the panels joinable across tables.
canonical_industry = function(label) {
  k = match_key(label)
  k = ifelse(k %in% names(INDUSTRY_ALIASES), unname(INDUSTRY_ALIASES[k]), k)
  INDUSTRIES[match(k, INDUSTRY_MATCH)]
}

row_type_of = function(industry) {
  ifelse(industry == ALL_INDUSTRIES, 'all_industries',
         ifelse(industry %in% NOT_ALLOCABLE, 'not_allocable', 'sector'))
}

#=============================================================================
# Checks shared by the panels
#=============================================================================

#-------------------------------------------------------------
# Vintage repair: four files are published without minus signs
#-------------------------------------------------------------

# Some SOI files were typeset with minus signs stripped from part of the body,
# which shows as a count of negative cells far below what the vintages either
# side carry:
#
#   07co01ccr.xls, 07co06ccr.xls, 07co07ccr.xls  (Tables 1, 6, 7 for TY2007)
#   08co13ccr.xls                                (Table 13 for TY2008)
#
# 07co06ccr.xls holds 6 negative cells against 46 in TY2006 and 68 in TY2008;
# 08co13ccr.xls holds 6 against 24 in TY2007 and 17 in TY2009. Tables 12 and
# the rest of the span are unaffected. Which published cells lost their sign is
# established, not guessed -- every entry below both (a) is the ONLY set of
# cells whose restoration makes that item's sector detail add to its total, as
# searched over all subsets up to six industries to the nearest thousand, and
# (b) is corroborated:
#
#   * Table 5.1's equity build-up (capital stock + additional paid-in capital
#     + retained earnings appropriated + retained earnings unappropriated -
#     cost of treasury stock) reproduces Table 1's independently published net
#     worth for EVERY industry in TY2006 and TY2008. In TY2007 it overshoots
#     for six industries, each time by exactly twice that industry's retained
#     earnings, unappropriated -- which is the set below. Restored, the sum
#     closes to 9e-10, from 15.4% out.
#   * The capital gain item names the same two industries in Tables 6 and 7
#     independently, and TY2007 is the one year in which either is positive.
#   * Table 1's own net worth row is stripped for the two not-allocable
#     residuals. That accounts for the whole of its 2.5e-06 gap, which was
#     otherwise the worst in that panel; restoring the two closes it to 3e-11.
#   * Table 13's three TY2008 industries are negative in TY2006, TY2007 and
#     TY2009 and positive only in TY2008; restored, the sum closes to 2.9e-10.
#
# The sign is all that is wrong -- every magnitude is confirmed by the identity
# it sits in -- so the cells are restored rather than dropped, and every panel
# asserts afterwards that its sums close.
UNSIGNED_CELLS = list(
  list(id = 'table_01', year = 2007,
       item = 'net worth', industries = NOT_ALLOCABLE),

  list(id = 'table_05_1', year = 2007,
       item = 'retained earnings, unappropriated',
       industries = c('information',
                      'professional, scientific, and technical services',
                      'health care and social assistance',
                      'arts, entertainment, and recreation', NOT_ALLOCABLE)),
  list(id = 'table_05_1', year = 2007,
       item = 'net short-term capital gain less net long-term loss',
       industries = c('information', 'accommodation and food services')),
  # the two residual columns again, on the pair of net items where their loss
  # shows: flipping both moves each sum by 64,726 against gaps of 64,725 and
  # 64,727, where the vintages either side close to a single unit
  list(id = 'table_05_1', year = 2007,
       item = 'total receipts less total deductions',
       industries = NOT_ALLOCABLE),
  list(id = 'table_05_1', year = 2007,
       item = 'net income (less deficit)', industries = NOT_ALLOCABLE),

  list(id = 'table_05_2', year = 2007,
       item = 'retained earnings, unappropriated',
       industries = c('health care and social assistance',
                      'wholesale and retail trade not allocable')),
  list(id = 'table_05_2', year = 2007,
       item = 'net short-term capital gain less net long-term loss',
       industries = c('information', 'accommodation and food services')),

  list(id = 'table_05_4', year = 2008,
       item = 'retained earnings, unappropriated',
       industries = c('information',
                      'professional, scientific, and technical services',
                      'health care and social assistance')),

  # The 1120S files for TY2007 and TY2009 are stripped WHOLESALE -- not a
  # handful of cells but every minus sign in the file: each of the four holds
  # zero negative values where the vintages around it hold 5 to 78. The sector
  # identity is still a valid instrument there, because the all-industries
  # total of a 1120S item is virtually never negative itself (5 such cells in
  # the entire set outside these two years, all in the two items withheld
  # below). So an item that reconciles had no sector cell stripped, and an
  # item that does not is repaired when the flip set is unique. Both rental
  # entries are confirmed twice over: 1120S Tables 1 and 5 publish the same
  # rental line and point independently at the same industries.
  list(id = 'table_06_1', year = 2007, item = 'retained earnings',
       industries = c('agriculture, forestry, fishing and hunting',
                      'arts, entertainment, and recreation',
                      'wholesale and retail trade not allocable')),
  list(id = 'table_06_1', year = 2009, item = 'retained earnings',
       industries = c('agriculture, forestry, fishing and hunting', 'information',
                      'arts, entertainment, and recreation',
                      'accommodation and food services', 'other services')),
  list(id = 'table_07', year = 2007,
       item = 'real estate rental net income (less deficit)',
       industries = c('finance and insurance',
                      'management of companies (holding companies)')),
  list(id = 'table_07', year = 2007,
       item = 'net income (less deficit) from other rental activity',
       industries = 'finance and insurance'),
  list(id = 'table_07', year = 2009, item = 'net long-term capital gain (loss)',
       industries = 'utilities'),
  list(id = 'table_07', year = 2009,
       item = 'real estate rental net income (less deficit)',
       industries = c('construction',
                      'management of companies (holding companies)')),
  list(id = 'table_08', year = 2007,
       item = 'real estate rental net income (less deficit)',
       industries = c('finance and insurance',
                      'management of companies (holding companies)')),
  list(id = 'table_08', year = 2009,
       item = 'real estate rental net income (less deficit)',
       industries = c('construction',
                      'management of companies (holding companies)'))
)

#-------------------------------------------------------------
# Cells SOI publishes that cannot be repaired, and are withdrawn
#-------------------------------------------------------------

# Where a published file is wrong in a way no identity can resolve, the cells
# are withdrawn -- value NA, flag 'unreconciled' -- rather than carried as
# published or guessed at. Every case is listed here with what makes it
# irreparable, and the sum check then skips it, because a withdrawn component
# leaves the item's sum undefined.
WITHHELD_CELLS = list(
  # The only two 1120S items whose ALL-INDUSTRIES total itself goes negative
  # elsewhere in the span. In the wholesale-unsigned TY2007 and TY2009 files
  # the total is therefore as suspect as the detail, so the sector identity
  # cannot pin the cells down -- and indeed no unique flip set exists for
  # either year.
  list(id = 'table_07', years = c(2007, 2009),
       item = 'net short-term capital gain (loss)'),
  list(id = 'table_08', years = c(2007, 2009),
       item = 'net gain (less loss) sales of business property'),
  # Unsigned TY2007 again, but with two different flip sets closing the
  # identity equally well; nothing chooses between them.
  list(id = 'table_08', years = 2007,
       item = 'net income (less deficit) from partnerships and fiduciaries'),
  # TY2013 is NOT one of the unsigned files (50 negative values), yet its
  # sector detail falls 0.6% SHORT of the total on this one split -- the wrong
  # direction for a lost sign, and no subset closes it. Unexplained.
  list(id = 'table_07', years = 2013,
       item = 'total net income (less deficit): deficit'),
  # SOI left a computed row in the TY2021 sheet: the values carry
  # floating-point noise (all industries 27,054,644.399995599) and several
  # sectors are negative, which a tax total cannot be. Detail is 3.7x the
  # total. TY2020 and TY2022 are clean.
  list(id = 'table_06_2', years = 2021, item = 'total income tax')
)

withhold_cells = function(panel, id) {
  for (spec in WITHHELD_CELLS) {
    if (spec$id != id) next
    hit = panel$tax_year %in% spec$years & panel$item == spec$item
    if (!any(hit)) {
      stop(sprintf('%s: nothing to withhold for "%s"', id, spec$item))
    }
    panel$value[hit] = NA_real_
    panel$flag[hit] = 'unreconciled'
    message(sprintf('  withheld %d unreconciled cells: %s, %s',
                    sum(hit), spec$item, paste(spec$years, collapse = '/')))
  }
  panel
}

restore_stripped_signs = function(panel, id) {
  for (spec in UNSIGNED_CELLS) {
    if (spec$id != id) next
    hit = panel$tax_year == spec$year & panel$item == spec$item &
      panel$industry %in% spec$industries
    if (sum(hit) != length(spec$industries)) {
      stop(sprintf('%s TY%d sign repair: expected %d cells of "%s", found %d',
                   id, spec$year, length(spec$industries), spec$item, sum(hit)))
    }
    if (any(panel$value[hit] <= 0, na.rm = TRUE)) {
      stop(sprintf('%s TY%d sign repair: "%s" is not published unsigned',
                   id, spec$year, spec$item))
    }
    panel$value[hit] = -panel$value[hit]
    message(sprintf('  TY%d: restored the minus sign on %d %s cells',
                    spec$year, length(spec$industries), spec$item))
  }
  panel
}

# Sector detail must add to the all-industries total -- the check that guards
# every choice below: which rows/columns are sectors, which are aggregates to
# skip, and the tie-breaks for repeated labels. SOI rounds each cell to
# thousands and warns that detail may not add to totals, so a gap has to clear
# BOTH a relative and an absolute floor to count: one unit of the published
# rounding is 1e-4 of a small item like TY1999 recapture taxes ($9.8 million),
# which would otherwise fail on nothing. Items with any suppressed ('d') or
# missing component are skipped because their sum is not defined. Real
# structural errors land in the percent range, orders above either floor.
check_sums = function(panel, tol = 1e-4, abs_tol = 2) {
  worst = list()
  for (year in unique(panel$tax_year)) {
    p = panel[panel$tax_year == year, ]
    for (item in unique(p$item)) {
      pi = p[p$item == item, ]
      parts = pi$value[pi$row_type %in% c('sector', 'not_allocable')]
      total = pi$value[pi$row_type == 'all_industries']
      if (length(total) != 1 || anyNA(parts) || is.na(total) || total == 0) next
      worst[[length(worst) + 1]] =
        data.frame(tax_year = year, item = item, total = total,
                   sum_parts = sum(parts),
                   abs_gap = abs(sum(parts) - total),
                   rel_gap = abs(sum(parts) - total) / abs(total))
    }
  }
  w = do.call(rbind, worst)
  w = w[order(-w$rel_gap), ]
  bad = w[w$rel_gap > tol & w$abs_gap > abs_tol, ]
  if (nrow(bad) > 0) {
    stop(sprintf('sector detail does not add to the total (tol %.1e):\n%s',
                 tol,
                 paste(sprintf('  %d %s: total %.0f vs sum %.0f (%.3f%%)',
                               bad$tax_year, bad$item, bad$total,
                               bad$sum_parts, 100 * bad$rel_gap),
                       collapse = '\n')))
  }
  w
}

report_sums = function(label, panel, abs_tol = 2) {
  gaps = check_sums(panel, abs_tol = abs_tol)
  # report the worst gap that is more than the published rounding, so the
  # headline number says something about structure rather than about a
  # one-unit difference on a tiny item
  material = gaps[gaps$abs_gap > abs_tol, ]
  message(sprintf('%s sum check: %d year x item combinations, worst relative gap %.2e (%d %s)',
                  label, nrow(gaps), material$rel_gap[1], material$tax_year[1],
                  material$item[1]))
}

# All-industries and every sector present in every year (the residual rows are
# published for part of the span only, so they are not required)
check_every_year = function(label, panel, years) {
  by_industry = table(unique(panel[, c('tax_year', 'industry')])$industry)
  n_full = sum(by_industry == length(years))
  if (n_full < 1 + length(SECTORS)) {
    stop(label, ': an industry is missing from at least one year')
  }
}

write_panel = function(id, panel) {
  dir.create(file.path(dest, 'aligned'), recursive = TRUE, showWarnings = FALSE)
  out_path = file.path(dest, 'aligned', paste0(id, '.csv'))
  write.csv(panel, out_path, row.names = FALSE, na = '')
  message(sprintf('%s: wrote %s (%d rows; %d industries, %d items, %d years %d-%d)',
                  id, out_path, nrow(panel), length(unique(panel$industry)),
                  length(unique(panel$item)), length(unique(panel$tax_year)),
                  min(panel$tax_year), max(panel$tax_year)))
}

#=============================================================================
# Table 1 -- industries in the ROWS, headline items in the columns
#=============================================================================

#---------------------------------
# Where Table 1 lives, by vintage
#---------------------------------

# Look up one file in an archive year, case-insensitively: several vintages
# ship UPPERCASE .XLS extensions (1999/2001 Table 1, 2001 Table 1 CV).
archive_file = function(year, pattern, what) {
  dir = sprintf('archive/%d', year)
  hit = list.files(file.path(dest, dir), pattern = pattern, ignore.case = TRUE)
  if (length(hit) != 1) {
    stop(sprintf('%d %s: expected one %s in %s, found %d',
                 year, what, pattern, dir, length(hit)))
  }
  file.path(dir, hit)
}

# The modern files are one per year; the archive filenames change scheme
# three times. Two splits to know about: 2004-2005 put the estimates in the
# 'a' file and the CVs in the 'b' file, and TY1998 publishes no separate CV
# file at all -- its CVs are columns 21-40 of the estimates sheet, which the
# column-block selection in t1_extract() picks out.
t1_file = function(year, measure) {
  yy = sprintf('%02d', year %% 100)
  find = function(pattern) archive_file(year, pattern, measure)
  if (measure == 'estimate') {
    if (year >= 2014) return(sprintf('modern/table_01/table_01_%d.xlsx', year))
    if (year >= 2006) return(find(sprintf('^%sco01ccr\\.xls$',  yy)))
    if (year >= 2004) return(find(sprintf('^%sco01accr\\.xls$', yy)))
    return(find(sprintf('^%sco01nr\\.xls$', yy)))
  }
  if (year >= 2014) {
    return(sprintf('modern/table_01_cv/table_01_cv_%d.xlsx', year))
  }
  if (year >= 2006) return(find(sprintf('^%sco01cv\\.xls$',    yy)))
  if (year >= 2004) return(find(sprintf('^%sco01bccr\\.xls$',  yy)))
  if (year >= 1999) return(find(sprintf('^%sco01cv\\.xls$',    yy)))
  find(sprintf('^%sco01nr\\.xls$', yy))   # TY1998: CVs sit in the same sheet
}

#------------------------------------
# Items: the columns, in published order
#------------------------------------

# Table 1's columns are VARIABLES, not labels (the same situation as Table 4),
# so they are mapped positionally and every mapping is verified against the
# published header by T1_ITEM_CHECK. The credit detail thins out in two
# steps -- the nonconventional source fuel credit ends after 2005 and the
# U.S. possessions credit after 2006 -- and the modern table carries no
# credit detail at all, only tax before and after credits.
T1_ITEMS_HEAD = c(
  'number of returns', 'number of returns with net income',
  'total receipts', 'total receipts of returns with net income',
  'business receipts', 'cost of goods sold', 'net income', 'deficit',
  'income subject to tax', 'total income tax before credits')
T1_ITEMS_TAIL = c(
  'total income tax after credits', 'total assets', 'net worth',
  'depreciable assets', 'depreciation deduction')

t1_items = function(year) {
  credits =
    if (year <= 2005)  c('foreign tax credit', 'u.s. possessions tax credit',
                         'nonconventional source fuel credit',
                         'general business credit',
                         'prior year minimum tax credit')
    else if (year == 2006) c('foreign tax credit', 'u.s. possessions tax credit',
                             'general business credit',
                             'prior year minimum tax credit')
    else if (year <= 2013) c('foreign tax credit', 'general business credit',
                             'prior year minimum tax credit')
    else character(0)
  c(T1_ITEMS_HEAD, credits, T1_ITEMS_TAIL)
}

# Keyword each mapped column's stacked header must contain. The first four
# columns are two-level headers ("Number of returns | Total", "Total
# receipts | Returns with net income"), which is why they are matched on the
# distinguishing phrase rather than the whole string.
T1_ITEM_CHECK = c(
  'number of returns'                        = 'number of returns',
  'number of returns with net income'        = 'with net income',
  'total receipts'                           = 'total receipts',
  'total receipts of returns with net income'= 'returns with net income',
  'business receipts'                        = 'business receipts',
  'cost of goods sold'                       = 'cost of goods sold',
  'net income'                               = '^net income',
  'deficit'                                  = 'deficit',
  'income subject to tax'                    = 'subject to tax',
  'total income tax before credits'          = 'before credits',
  'foreign tax credit'                       = 'foreign',
  'u.s. possessions tax credit'              = 'possessions',
  'nonconventional source fuel credit'       = 'fuel',
  'general business credit'                  = 'business credit',
  'prior year minimum tax credit'            = 'minimum',
  'total income tax after credits'           = 'after credits',
  'total assets'                             = 'total assets',
  'net worth'                                = 'net worth',
  'depreciable assets'                       = 'depreciable',
  'depreciation deduction'                   = 'depreciation deduction'
)

#-------------------------------------------------
# Vintage repair: the TY2000 wholesale/retail block
#-------------------------------------------------

# SOI's TY2000 Table 1 file publishes 30 contiguous rows -- the wholesale and
# retail block, "Wholesale trade, durable goods" through "General merchandise
# stores" -- with the last SIX columns rotated one position LEFT: the
# prior-year-minimum-tax-credit value sits in the final column and every other
# value one column early. Three independent confirmations:
#   * under the published order those rows report tax after credits far above
#     tax BEFORE credits, and net worth above total assets -- both impossible;
#   * after rotating back, the credits identity closes exactly (Retail trade:
#     16,807,119 before credits - 689,114 credits = 16,118,005 after);
#   * the rotated values are smooth against the neighbouring vintages (Retail
#     trade tax after credits 15.46B in 1999 -> 16.12B -> 16.14B in 2001).
# No other vintage 1998-2013 contains a single definitionally impossible row,
# so the repair is scoped to this one file and asserts that it worked.
impossible_row = function(v) {
  over = function(a, b) {
    !is.na(v[a]) && !is.na(v[b]) && v[a] > v[b] * (1 + 1e-4)
  }
  over('total income tax after credits', 'total income tax before credits') ||
    over('net worth', 'total assets')
}

# Estimates only: the CV file for TY2000 is NOT shifted (its retail-trade
# block keeps the large prior-year-minimum-credit CV in the first of the last
# six columns, exactly as 1999 and 2001 do), and the impossibility test above
# is meaningless on percentages anyway.
repair_rotated_block = function(df, year, items, measure) {
  if (year != 2000 || measure != 'estimate') return(df)
  block = tail(items, 6)   # prior year minimum tax credit .. depreciation
  rot = c(length(block), seq_len(length(block) - 1))
  n_fixed = 0
  for (rs in unique(df$row_seq)) {
    idx = which(df$row_seq == rs)
    v = setNames(df$value[idx], df$item[idx])
    if (!impossible_row(v)) next
    bidx = idx[match(block, df$item[idx])]
    if (anyNA(bidx)) stop('TY2000 repair: row ', rs, ' lacks the rotated block')
    df$value[bidx] = df$value[bidx][rot]
    df$flag[bidx]  = df$flag[bidx][rot]
    if (impossible_row(setNames(df$value[idx], df$item[idx]))) {
      stop(sprintf('TY2000 repair did not resolve row %d ("%s")', rs,
                   df$row_label[idx][1]))
    }
    n_fixed = n_fixed + 1
  }
  if (n_fixed > 0) {
    message(sprintf('  TY2000: rotated the last 6 columns back on %d rows',
                    n_fixed))
  }
  df
}

#--------------------
# Parse one vintage
#--------------------

CV_SPANNER = 'coefficient of variation'

t1_extract = function(year, measure) {
  path = file.path(dest, t1_file(year, measure))
  if (!file.exists(path)) {
    stop('missing input (run download_irs_corp.R first): ', path)
  }
  df = extract_sheet(path, script_dir,
                     paren_negative = (measure == 'estimate'))
  items = t1_items(year)

  # Pick this measure's column block. A sheet holding both (TY1998's estimates
  # sheet, whose CVs are columns 21-40) is split at the first column whose
  # stacked header carries the CV spanner: estimates are the columns before it,
  # CVs that column onwards. In a standalone CV file the spanner sits on column
  # 1, so the same rule keeps everything.
  hdr = unique(df[, c('col_seq', 'col_label')])
  hdr = hdr[order(hdr$col_seq), ]
  cv = grep(CV_SPANNER, tolower(hdr$col_label))
  if (length(cv) > 0) {
    hdr = if (measure == 'estimate') hdr[hdr$col_seq <  min(hdr$col_seq[cv]), ]
          else                       hdr[hdr$col_seq >= min(hdr$col_seq[cv]), ]
  } else if (measure == 'cv') {
    stop(sprintf('%s: no "%s" header found in a CV source', path, CV_SPANNER))
  }
  if (nrow(hdr) != length(items)) {
    stop(sprintf('%s: expected %d %s columns, found %d',
                 path, length(items), measure, nrow(hdr)))
  }
  for (k in seq_along(items)) {
    # the spanner prefixes the first column of every printed panel, so strip
    # it before matching the item keyword (which may be anchored)
    h = trimws(sub(paste0('.*', CV_SPANNER, ' \\(percent\\)'), '',
                   tolower(hdr$col_label[k])))
    if (!grepl(T1_ITEM_CHECK[[items[k]]], h)) {
      stop(sprintf('%s: column %d header does not look like "%s": "%s"',
                   path, k, items[k], h))
    }
  }
  df = df[df$col_seq %in% hdr$col_seq, ]
  df$item = items[match(df$col_seq, hdr$col_seq)]
  df = repair_rotated_block(df, year, items, measure)
  df$industry = canonical_industry(df$row_label)

  # Pick the FIRST row carrying each wanted industry. Duplicates exist:
  # 1998-2003 wrap some minor-industry labels so that a continuation fragment
  # ("manufacturing", lowercase) repeats a sector name further down the stub.
  # A sector row always precedes the minors beneath it, so first-by-row_seq
  # is the sector; the sum check is the guard on that rule.
  keep = df[!is.na(df$industry), ]
  first_seq = tapply(keep$row_seq, keep$industry, min)
  keep = keep[keep$row_seq == first_seq[keep$industry], ]

  missing = setdiff(c(ALL_INDUSTRIES, SECTORS), unique(keep$industry))
  if (length(missing) > 0) {
    stop(sprintf('%s: sector row(s) not found: %s',
                 path, paste(missing, collapse = '; ')))
  }
  keep$row_type = row_type_of(keep$industry)
  keep$unit = if (measure == 'cv') 'cv_pct' else {
    ifelse(grepl('^number of returns', keep$item), 'count', 'thousand_usd')
  }
  keep = keep[order(match(keep$industry, INDUSTRIES), match(keep$item, items)), ]
  data.frame(tax_year = year,
             keep[, c('row_type', 'industry', 'item', 'value', 'flag', 'unit')],
             row.names = NULL, stringsAsFactors = FALSE)
}

build_t1 = function(measure) {
  panels = lapply(INDUSTRY_YEARS, function(year) {
    p = t1_extract(year, measure)
    message(sprintf('  %d: %3d industries x %2d items = %4d cells  [%s]',
                    year, length(unique(p$industry)), length(unique(p$item)),
                    nrow(p), basename(t1_file(year, measure))))
    p
  })
  do.call(rbind, panels)
}

message('table_01 (estimates)')
panel = restore_stripped_signs(build_t1('estimate'), 'table_01')
report_sums('table_01', panel)
check_every_year('table_01', panel, INDUSTRY_YEARS)

message('table_01_cv (coefficients of variation)')
cv_panel = build_t1('cv')
check_every_year('table_01_cv', cv_panel, INDUSTRY_YEARS)

# The CV panel cannot be checked by addition -- CVs do not add -- so it is
# checked against the estimates panel it must parallel, cell for cell.
key_of = function(p) paste(p$tax_year, p$industry, p$item, sep = '|')
missing_cv = setdiff(key_of(panel), key_of(cv_panel))
extra_cv   = setdiff(key_of(cv_panel), key_of(panel))
if (length(missing_cv) > 0 || length(extra_cv) > 0) {
  stop(sprintf('CV panel does not parallel the estimates: %d cells without a CV, %d CVs without an estimate\n  e.g. %s',
               length(missing_cv), length(extra_cv),
               paste(head(c(missing_cv, extra_cv), 3), collapse = ' ; ')))
}

# A CV may be negative only where its own estimate is negative: SOI carries the
# sign of the mean, which happens for the negative net worth of the
# not-allocable residuals (2000, 2001, 2005). Any OTHER negative CV is a
# footnote reference that reached the sheet as a number rather than as text --
# in the TY2000 CV file six cells hold the number -4 where "(4)" was meant
# (clean_value's paren_negative = FALSE catches the ones still written as text,
# such as the 161 "(4)" cells in TY2010). Those carry no CV, so they become NA
# with a '(4)' flag; more than a handful would mean something systemic.
bogus = with(cv_panel, !is.na(value) & value < 0)
if (any(bogus)) {
  est_value = panel$value[match(key_of(cv_panel)[bogus], key_of(panel))]
  bogus[bogus] = is.na(est_value) | est_value >= 0
}
if (sum(bogus) > 10) {
  stop(sprintf('%d negative CVs whose estimate is not negative -- expected a handful',
               sum(bogus)))
}
if (any(bogus)) {
  message(sprintf('  CV: %d negative cell(s) with a non-negative estimate treated as "(4)" footnotes: %s',
                  sum(bogus), paste(key_of(cv_panel)[bogus], collapse = ' ; ')))
  cv_panel$flag[bogus]  = '(4)'
  cv_panel$value[bogus] = NA_real_
}

cv_vals = cv_panel$value[!is.na(cv_panel$value)]
neg = sum(cv_vals < 0)
if (min(cv_vals) < -1000 || max(cv_vals) > 1000) {
  stop(sprintf('CV values outside [-1000, 1000]: min %.2f, max %.2f',
               min(cv_vals), max(cv_vals)))
}
message(sprintf('CV check: %d cells parallel the estimates exactly; CVs in [%.2f, %.2f], %d negative (negative estimates)',
                nrow(cv_panel), min(cv_vals), max(cv_vals), neg))

write_panel('table_01', panel)
write_panel('table_01_cv', cv_panel)

#=============================================================================
# Tables 5.x and the 1120S set -- item stub in the ROWS, industries in COLUMNS
#=============================================================================

# Every table below reports the same kind of thing in the same shape: an item
# stub down the side, industries across the top, one table per universe of
# returns. So one spec list drives all of them, and the differences that
# remain are the file map and the span.
#
# The 5.x family covers all corporations. 5.3/5.4 exclude the pass-throughs
# and regulated forms 5.1/5.2 include, which is why 5.3 <= 5.1 and 5.4 <= 5.2
# return for return. The 1120S set covers the S corporations 5.3/5.4 leave
# out, and its old files are far patchier -- see t5_file below.
T5_SPECS = list(
  list(id = 'table_05_1', form = 'ccr', old = '06', old_suffix = 'nr',
       years = 1998:2022, wrapped_stubs = TRUE, s_stub = FALSE,
       universe = 'all active corporations'),
  list(id = 'table_05_2', form = 'ccr', old = '07', old_suffix = 'nr',
       years = 1998:2022, wrapped_stubs = TRUE, s_stub = FALSE,
       universe = 'returns with net income'),
  list(id = 'table_05_3', form = 'ccr', old = '12', old_suffix = 'mi',
       years = 1998:2022, wrapped_stubs = TRUE, s_stub = FALSE,
       universe = 'active corporations other than 1120S, 1120-REIT, 1120-RIC'),
  list(id = 'table_05_4', form = 'ccr', old = '13', old_suffix = 'mi',
       years = 1998:2022, wrapped_stubs = TRUE, s_stub = FALSE,
       universe = 'returns with net income, other than 1120S, 1120-REIT, 1120-RIC'),

  list(id = 'table_06_1', form = '1120s', old = '07', years = 2006:2022,
       wrapped_stubs = FALSE, s_stub = TRUE,
       universe = 'Form 1120S, active corporations -- balance sheet'),
  list(id = 'table_06_2', form = '1120s', old = '08', years = 2006:2022,
       wrapped_stubs = FALSE, s_stub = TRUE,
       universe = 'Form 1120S, returns with net income -- balance sheet'),
  list(id = 'table_07', form = '1120s', old = '01',
       years = c(2004, 2006:2007, 2009:2022),
       wrapped_stubs = FALSE, s_stub = TRUE,
       universe = 'Form 1120S, active corporations -- income'),
  list(id = 'table_08', form = '1120s', old = '05',
       years = c(2004, 2006:2007, 2009:2022),
       wrapped_stubs = FALSE, s_stub = TRUE,
       universe = 'Form 1120S, rental real estate (Form 8825)')
)

#-------------------------------------
# Where the files live, by vintage
#-------------------------------------

# Corporate archive filenames carry a per-table suffix that changes at the
# 2004 switch to 'ccr': Tables 6 and 7 are '{yy}co06nr.xls'/'{yy}co07nr.xls'
# before it, Tables 12 and 13 '{yy}co12mi.xls'/'{yy}co13mi.xls'. TY1999 ships
# the latter two with UPPERCASE .XLS, so the lookup is case-insensitive.
#
# The 1120S files are their own scheme and their own, gappier span:
#   TY2004        '{yy}co1120s{NN}.xls', 1120S Tables 1, 2, 4, 5, 6 only
#   TY2005        NOTHING -- that year's zip omits the 1120S set entirely
#                 (and Tables 14/15 with it)
#   TY2006-2013   '{yy}co{NN}s.xls', all seven, EXCEPT TY2008, which ships
#                 only 1120S Tables 7 and 8
# So the two balance-sheet panels run 2006-2022 unbroken while the other two
# lose 2005 and 2008 -- hence the per-spec `years`. Old 1120S Table 2 (returns
# with net income, income items) has no modern successor and is not aligned.
t5_file = function(spec, year) {
  if (year >= 2014) {
    return(sprintf('modern/%s/%s_%d.xlsx', spec$id, spec$id, year))
  }
  yy = sprintf('%02d', year %% 100)
  pattern =
    if (spec$form == '1120s') {
      if (year >= 2006) sprintf('^%sco%ss\\.xls$', yy, spec$old)
      else              sprintf('^%sco1120s%s\\.xls$', yy, spec$old)
    } else {
      sprintf('^%sco%s%s\\.xls$', yy, spec$old,
              if (year >= 2004) 'ccr' else spec$old_suffix)
    }
  archive_file(year, pattern, spec$id)
}

#-------------------------------------------------
# Which column is a sector's own column
#-------------------------------------------------

# A wide vintage repeats the spanner over each later printed panel, tagged
# "-- continued" ("Manufacturing--continued Wood product manufacturing"); the
# tagged copy names no column and comes off before anything else is read.
strip_continued = function(hdr) {
  gsub('[a-z0-9 ,&()./-]*--\\s*continued', ' ', tolower(hdr))
}

# Does this column report a whole block rather than one industry? Every
# sector's own column is the "Total" of its block, whatever else stacked on
# top of it.
is_block_total = function(hdr) grepl('\\btotal\\b', strip_continued(hdr))

# The industry a data column stands for, reduced from its stacked header by
# dropping the "Total" that marks a block total rather than naming an
# industry, and collapsing the doubled phrase left behind when the sector name
# stacks over both the spanner row and the leaf ("Coal mining Coal mining").
# What survives is the industry's own name for a sector total column, the
# minor industry's name for a detail column, and nothing at all for a total
# column whose block is named somewhere other than directly above it.
block_key = function(hdr) {
  # TY2007's 1120S files carry no column-number row at all: the number is
  # printed inside each header cell instead ("Mining (6)"), so it rides along
  # in the stacked label and has to come off before the name is read.
  k = sub('\\s*\\([0-9]+\\)\\s*$', '', strip_continued(hdr))
  k = match_key(gsub('\\btotal\\b', ' ', k))
  vapply(k, function(one) {
    w = strsplit(one, ' ', fixed = TRUE)[[1]]
    h = length(w) %/% 2
    if (h > 0 && length(w) %% 2 == 0 && identical(w[1:h], w[(h + 1):(2 * h)])) {
      one = paste(w[1:h], collapse = ' ')
    }
    one
  }, character(1), USE.NAMES = FALSE)
}

# Map every data column onto the industry it reports, NA for the ones we drop
# (minor industries, the supersectors, the wholesale and retail trade
# aggregate). Three passes, each catching what the one before could not.
column_industry = function(col_label) {
  bkey = block_key(col_label)
  total = is_block_total(col_label)
  industry = canonical_industry(bkey)

  # (2) Wholesale and retail trade nest inside an aggregate whose spanner
  # stacks on top of theirs, so from 2007 on the wholesale column is headed
  # "Wholesale and retail trade Wholesale trade Total" -- aggregate name and
  # then its own. Only that exact composition counts: matching a bare suffix
  # would hand Retail trade the AGGREGATE's own column, whose key ends in the
  # same two words.
  for (sector in setdiff(SECTORS, industry)) {
    nested = paste(match_key(AGGREGATES), match_key(sector))
    hit = which(total & is.na(industry) & bkey %in% nested)
    if (length(hit) > 0) industry[hit[1]] = sector
  }

  # (3) TY1998 and TY2000 CENTRE each spanner over its block instead of
  # anchoring it, so the name lands on one of the block's minor industries and
  # the sector's own column is left headed bare "Total" -- "Agriculture,
  # forestry, fishing, and hunting" sits over "Agricultural production", and
  # "Manufacturing" two columns further on over "Beverage and tobacco product
  # manufacturing". Centred text still falls inside its own block, so the
  # sector's column is the last unclaimed block total at or before the
  # leftmost column whose header its name opens. Sectors are resolved in
  # published (left-to-right) order, so each takes the nearest total its
  # predecessors have not already taken.
  for (sector in setdiff(c(ALL_INDUSTRIES, SECTORS), industry)) {
    opens = startsWith(bkey, paste0(match_key(sector), ' '))
    if (!any(opens)) next
    cand = which(total & is.na(industry))
    cand = cand[cand <= min(which(opens))]
    if (length(cand) == 0) next
    industry[max(cand)] = sector
  }
  industry
}

#-------------------------------------------------
# Which row is which item
#-------------------------------------------------

# SOI also breaks a long item name over two stub lines and puts the data on
# the SECOND, so extract_sheet reads the first line as a section header
# ("Mortgages, notes, and bonds payable in less" + "than one year"). Whether a
# section header means a wrap is a property of the published stub, and the two
# families differ -- both enumerated across every vintage:
#   * in the 5.x family EVERY section header is a wrap, so the row directly
#     below one is glued back onto it, which reproduces the published label
#     and lets ITEM_ALIASES harmonize it like any other;
#   * the 1120S family produces only two section headers, "Income from trade
#     or business" and "Total receipts", and both are real GROUPINGS over the
#     rows beneath them. Gluing there would invent an item ("Income from trade
#     or business Total receipts") and break its series in two.
t5_row_items = function(df, spec) {
  rows = unique(df[, c('row_seq', 'section', 'row_label')])
  rows = rows[order(rows$row_seq), ]
  prev = c(NA_character_, head(rows$section, -1))
  wrapped = spec$wrapped_stubs &
    !is.na(rows$section) & (is.na(prev) | rows$section != prev)
  item = apply_alias(ifelse(wrapped, paste(rows$section, rows$row_label),
                            rows$row_label))
  # the 1120S stub carries its own renames and its split rows (see
  # alignment_helpers.R); the corporate stub has neither
  if (spec$s_stub) item = qualify_splits(apply_s_alias(item))
  rows$item = item
  rows[, c('row_seq', 'item')]
}

#--------------------
# Parse one vintage
#--------------------

t5_extract = function(spec, year) {
  path = file.path(dest, t5_file(spec, year))
  if (!file.exists(path)) {
    stop('missing input (run download_irs_corp.R first): ', path)
  }
  df = extract_sheet(path, script_dir)

  hdr = unique(df[, c('col_seq', 'col_label')])
  hdr = hdr[order(hdr$col_seq), ]
  hdr$industry = column_industry(hdr$col_label)
  missing = setdiff(c(ALL_INDUSTRIES, SECTORS), hdr$industry)
  if (length(missing) > 0) {
    stop(sprintf('%s: sector column(s) not found: %s',
                 path, paste(missing, collapse = '; ')))
  }
  named = hdr[!is.na(hdr$industry), ]
  if (anyDuplicated(named$industry)) {
    dup = named$industry[duplicated(named$industry)][1]
    stop(sprintf('%s: two columns claim industry "%s"', path, dup))
  }

  keep = df[df$col_seq %in% named$col_seq, ]
  keep$industry = named$industry[match(keep$col_seq, named$col_seq)]
  items = t5_row_items(df, spec)
  keep$item = items$item[match(keep$row_seq, items$row_seq)]
  if (anyDuplicated(keep[, c('industry', 'item')])) {
    dup = keep[duplicated(keep[, c('industry', 'item')]), ][1, ]
    stop(sprintf('%s: duplicate industry x item cell ("%s", "%s")',
                 path, dup$industry, dup$item))
  }

  keep$row_type = row_type_of(keep$industry)
  keep$unit = ifelse(grepl('^number of', keep$item), 'count', 'thousand_usd')
  keep = keep[order(match(keep$industry, INDUSTRIES), keep$row_seq), ]
  data.frame(tax_year = year,
             keep[, c('row_type', 'industry', 'item', 'value', 'flag', 'unit')],
             row.names = NULL, stringsAsFactors = FALSE)
}

t5 = list()
for (spec in T5_SPECS) {
  message(sprintf('%s (%s)', spec$id, spec$universe))
  p = do.call(rbind, lapply(spec$years, function(year) {
    q = t5_extract(spec, year)
    message(sprintf('  %d: %3d industries x %2d items = %4d cells  [%s]',
                    year, length(unique(q$industry)), length(unique(q$item)),
                    nrow(q), basename(t5_file(spec, year))))
    q
  }))
  p = withhold_cells(restore_stripped_signs(p, spec$id), spec$id)
  report_sums(spec$id, p)
  check_every_year(spec$id, p, spec$years)
  t5[[spec$id]] = p
}

#---------------------------------------------------
# Cross-checks: the 5.x family against Table 1, and
# against each other
#---------------------------------------------------

# 5.1 and 5.2 estimate quantities Table 1 also publishes, for the same
# industries and from the same sample, but reach them by an unrelated route --
# Table 1 reads them off row labels, the 5.x off column headers -- so the
# overlap tests the sector columns picked above. 5.1 covers all active
# corporations, which is Table 1's own universe; 5.2 covers returns with net
# income, which Table 1 carries as its two "with net income" columns.
T5_VS_T1 = list(
  table_05_1 = c('number of returns' = 'number of returns',
                 'total receipts'    = 'total receipts',
                 'business receipts' = 'business receipts',
                 'cost of goods sold'= 'cost of goods sold',
                 'income subject to tax' = 'income subject to tax',
                 'total income tax before credits' = 'total income tax before credits',
                 'total income tax after credits'  = 'total income tax after credits'),
  table_05_2 = c('number of returns' = 'number of returns with net income',
                 'total receipts' = 'total receipts of returns with net income')
)
for (id in names(T5_VS_T1)) {
  map = T5_VS_T1[[id]]
  p = t5[[id]]
  overlap = merge(
    transform(p[p$item %in% names(map), ],
              item = unname(map[item]), t5 = value)[
                , c('tax_year', 'industry', 'item', 't5')],
    transform(panel, t1 = value)[, c('tax_year', 'industry', 'item', 't1')],
    by = c('tax_year', 'industry', 'item'))
  ok = !is.na(overlap$t5) & !is.na(overlap$t1) & overlap$t1 != 0
  overlap$rel = abs(overlap$t5 - overlap$t1) / abs(overlap$t1)
  worst = overlap[ok, ][order(-overlap$rel[ok]), ][1, ]
  if (worst$rel > 1e-3) {
    stop(sprintf('%s disagrees with table_01: %d %s %s -- %.0f vs %.0f (%.2f%%)',
                 id, worst$tax_year, worst$industry, worst$item, worst$t5,
                 worst$t1, 100 * worst$rel))
  }
  message(sprintf('%s vs table_01: %d shared cells agree, worst relative gap %.2e (%d %s %s)',
                  id, sum(ok), worst$rel, worst$tax_year, worst$industry,
                  worst$item))
}

# Two 1120S tables classify the SAME universe -- Table 7 its income, Table 6.1
# its balance sheet -- from the same sample, so where they publish the same
# item they must agree to the digit. That is the sharpest check available on
# the S-corporation panels, which have no Table 1 counterpart.
by_cell = function(p, item) {
  q = p[p$item == item, ]
  setNames(q$value, paste(q$tax_year, q$industry))
}
for (item in c('number of returns', 'number of shareholders')) {
  a = by_cell(t5$table_07, item)
  b = by_cell(t5$table_06_1, item)[names(a)]
  ok = !is.na(a) & !is.na(b)
  if (any(a[ok] != b[ok])) {
    i = which(ok)[which(a[ok] != b[ok])[1]]
    stop(sprintf('table_07 and table_06_1 disagree on %s: %s, %.0f vs %.0f',
                 item, names(a)[i], a[i], b[i]))
  }
  message(sprintf('table_07 and table_06_1 agree on %s: %d shared cells, exactly',
                  item, sum(ok)))
}

# Nesting: each universe is a subset of the ones above it, so its return count
# can never exceed theirs. This is the only check that reaches 5.3, 5.4 and
# Table 8 -- and it is a real one, since a mis-assigned sector column would
# show up as one industry's count jumping above its own superset. The last
# pair crosses the two families: all corporations minus those other than
# 1120S/REIT/RIC leaves the S corporations plus the two regulated forms, which
# is an upper bound on the 1120S count.
T5_NESTED = list(c('table_05_2', 'table_05_1'), c('table_05_3', 'table_05_1'),
                 c('table_05_4', 'table_05_2'), c('table_05_4', 'table_05_3'),
                 c('table_06_2', 'table_06_1'), c('table_08', 'table_07'))
for (pair in T5_NESTED) {
  n_sub = by_cell(t5[[pair[1]]], 'number of returns')
  n_sup = by_cell(t5[[pair[2]]], 'number of returns')[names(n_sub)]
  bad = which(!is.na(n_sub) & !is.na(n_sup) & n_sub > n_sup)
  if (length(bad) > 0) {
    stop(sprintf('%s has more returns than %s: %s, %.0f vs %.0f',
                 pair[1], pair[2], names(n_sub)[bad[1]],
                 n_sub[bad[1]], n_sup[bad[1]]))
  }
  message(sprintf('%s nests inside %s: %d industry-years, all counts within',
                  pair[1], pair[2], sum(!is.na(n_sub) & !is.na(n_sup))))
}

# The S corporations are part of what Table 5.3 leaves out of Table 5.1, so
# their return count cannot exceed the difference (which also carries the
# 1120-REIT and 1120-RIC filers). Unlike the nestings above this compares a
# count against a DIFFERENCE of two separately published estimates, so it
# carries both their roundings -- TY2006 retail trade overshoots by exactly one
# return in 402,266. A few returns of slack; a real error would be thousands.
S_RETURNS_SLACK = 5
s_returns = by_cell(t5$table_06_1, 'number of returns')
gap_returns = by_cell(t5$table_05_1, 'number of returns')[names(s_returns)] -
  by_cell(t5$table_05_3, 'number of returns')[names(s_returns)]
ok = !is.na(s_returns) & !is.na(gap_returns)
over = ok & s_returns > gap_returns + S_RETURNS_SLACK
if (any(over)) {
  i = which(over)[1]
  stop(sprintf('table_06_1 exceeds table_05_1 less table_05_3: %s, %.0f vs %.0f',
               names(s_returns)[i], s_returns[i], gap_returns[i]))
}
message(sprintf('table_06_1 fits inside table_05_1 less table_05_3: %d industry-years, worst overshoot %.0f return(s)',
                sum(ok), max(0, max(s_returns[ok] - gap_returns[ok]))))

for (spec in T5_SPECS) write_panel(spec$id, t5[[spec$id]])
