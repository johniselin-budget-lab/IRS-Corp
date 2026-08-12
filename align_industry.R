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
# extract_sheet() from alignment_helpers.R.
#
# Builds:
#   aligned/table_01.csv      Table 1 at SECTOR level, 1998-2022
#   aligned/table_01_cv.csv   its coefficients of variation, same shape
#     tax_year, row_type (all_industries | sector | not_allocable),
#     industry, item, value, flag, unit
#   The two panels are parallel by construction -- same industries, same items,
#   same years, built by the same code over a different file map -- so a CV can
#   be joined onto its estimate on (tax_year, industry, item).
#
# WHY SECTOR LEVEL: minor-industry labels drift with every NAICS revision
# (2002, 2007, 2012, 2017), which needs a per-revision concordance; the 19
# SECTOR labels are stable across the whole span. WHY 1998: 1994-97 are
# SIC-coded, and only a coarse division-level bridge would be defensible.
# Both cuts are deliberate -- see notes/industry_tables.md.
#
# Row selection is by canonical sector NAME, not by stub indentation: the
# published indent is unusable as a level marker (SOI wraps sectors in
# supersectors in 1998-99, indents Utilities differently from its siblings,
# and drops stub indentation entirely from 2017 on). Every year must yield
# all 19 sectors or the run fails.
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

T1_YEARS = 1998:2022

#---------------------------------
# Where Table 1 lives, by vintage
#---------------------------------

# The modern files are one per year; the archive filenames change scheme
# three times, and several vintages ship UPPERCASE .XLS extensions
# (1999/2001), so the archive lookups are case-insensitive. Two splits to
# know about: 2004-2005 put the estimates in the 'a' file and the CVs in the
# 'b' file, and TY1998 publishes no separate CV file at all -- its CVs are
# columns 21-40 of the estimates sheet, which the column-block selection in
# t1_extract() picks out.
t1_file = function(year, measure) {
  yy = sprintf('%02d', year %% 100)
  find = function(pattern) {
    dir = sprintf('archive/%d', year)
    hit = list.files(file.path(dest, dir), pattern = pattern, ignore.case = TRUE)
    if (length(hit) != 1) {
      stop(sprintf('%d %s: expected one %s in %s, found %d',
                   year, measure, pattern, dir, length(hit)))
    }
    file.path(dir, hit)
  }
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

#---------------------------------------
# Industries: the rows we keep, and only those
#---------------------------------------

# The 19 NAICS sectors SOI publishes, in published order, under their modern
# labels. Aggregates that also sit at sector level in the stub -- the
# 1998-99 supersectors ("Goods production", ...) and "Wholesale and retail
# trade" (= wholesale + retail + their not-allocable residual) -- are
# deliberately NOT here: keeping them would double count.
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

# Residual rows, published 1998-2013 only: returns SOI could not assign to a
# sector. Kept (as row_type 'not_allocable') so that sectors + residuals
# reconcile against the all-industries row in those years; the modern table
# has no such rows.
NOT_ALLOCABLE = c('wholesale and retail trade not allocable', 'not allocable')

# Sector label variants -> canonical. Curated from the per-year stub survey.
# The administrative sector is the interesting one: 1998-2006 wrap its long
# name over TWO stub lines, and because the first line carries no data,
# extract_sheet treats it as a section header and the sector's data lands on
# the second line, "and remediation services".
SECTOR_ALIASES = c(
  'and remediation services' =
    'administrative and support and waste management and remediation services',
  'wholesale and retail not allocable' =
    'wholesale and retail trade not allocable'
)

# Normalized industry key: ampersands spelled out (the 1998-99 vintages write
# "Agriculture, forestry, fishing & hunting"), whitespace collapsed, then
# aliases applied. normalize_label() has already stripped footnote refs and
# dot leaders.
industry_key = function(label) {
  k = tolower(label)
  k = gsub('&', 'and', k)
  k = trimws(gsub('\\s+', ' ', k))
  ifelse(k %in% names(SECTOR_ALIASES), unname(SECTOR_ALIASES[k]), k)
}

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
  df$key  = industry_key(df$row_label)

  # Pick the FIRST row carrying each wanted key. Duplicates exist: 1998-2003
  # wrap some minor-industry labels so that a continuation fragment
  # ("manufacturing", lowercase) repeats a sector name further down the stub.
  # A sector row always precedes the minors beneath it, so first-by-row_seq
  # is the sector; the class-sum check below is the guard on that rule.
  want = c(ALL_INDUSTRIES, SECTORS, NOT_ALLOCABLE)
  keep = df[df$key %in% want, ]
  first_seq = tapply(keep$row_seq, keep$key, min)
  keep = keep[keep$row_seq == first_seq[keep$key], ]

  missing = setdiff(c(ALL_INDUSTRIES, SECTORS), unique(keep$key))
  if (length(missing) > 0) {
    stop(sprintf('%s: sector row(s) not found: %s',
                 path, paste(missing, collapse = '; ')))
  }
  keep$row_type = ifelse(keep$key == ALL_INDUSTRIES, 'all_industries',
                  ifelse(keep$key %in% NOT_ALLOCABLE, 'not_allocable', 'sector'))
  keep$unit = if (measure == 'cv') 'cv_pct' else {
    ifelse(grepl('^number of returns', keep$item), 'count', 'thousand_usd')
  }
  keep = keep[order(match(keep$key, want), match(keep$item, items)), ]
  data.frame(tax_year = year,
             keep[, c('row_type', 'key', 'item', 'value', 'flag', 'unit')],
             row.names = NULL, stringsAsFactors = FALSE)
}

#---------------------------
# Build and verify the panels
#---------------------------

build_panel = function(measure) {
  panels = lapply(T1_YEARS, function(year) {
    p = t1_extract(year, measure)
    message(sprintf('  %d: %3d industries x %2d items = %4d cells  [%s]',
                    year, length(unique(p$key)), length(unique(p$item)),
                    nrow(p), basename(t1_file(year, measure))))
    p
  })
  panel = do.call(rbind, panels)
  names(panel)[names(panel) == 'key'] = 'industry'
  panel
}

message('table_01 (estimates)')
panel = build_panel('estimate')

# Sector detail must add to the all-industries row -- the check that guards
# every choice above: which rows are sectors, which are aggregates to skip,
# and the first-occurrence rule for repeated labels. SOI rounds each cell to
# thousands and warns that detail may not add to totals, so the test is on
# relative gap; items with any suppressed ('d') or missing component are
# skipped because their sum is not defined. The worst observed gap across
# 1998-2022 is 2.5e-06 (2007 net worth), so 1e-04 leaves room for rounding
# while still catching a structural error, which lands in the percent range.
check_sums = function(panel, tol = 1e-4) {
  worst = list()
  for (year in unique(panel$tax_year)) {
    p = panel[panel$tax_year == year, ]
    for (item in unique(p$item)) {
      pi = p[p$item == item, ]
      parts = pi$value[pi$row_type %in% c('sector', 'not_allocable')]
      total = pi$value[pi$row_type == 'all_industries']
      if (length(total) != 1 || anyNA(parts) || is.na(total) || total == 0) next
      gap = abs(sum(parts) - total) / abs(total)
      worst[[length(worst) + 1]] =
        data.frame(tax_year = year, item = item, total = total,
                   sum_parts = sum(parts), rel_gap = gap)
    }
  }
  w = do.call(rbind, worst)
  w = w[order(-w$rel_gap), ]
  bad = w[w$rel_gap > tol, ]
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
gaps = check_sums(panel)
message(sprintf('sum check: %d year x item combinations, worst relative gap %.2e (%d %s)',
                nrow(gaps), gaps$rel_gap[1], gaps$tax_year[1], gaps$item[1]))

n_years = length(T1_YEARS)
every_year = function(panel) {
  by_industry = table(unique(panel[, c('tax_year', 'industry')])$industry)
  sum(by_industry == n_years) >= 1 + length(SECTORS)
}
if (!every_year(panel)) stop('an industry is missing from at least one year')

message('table_01_cv (coefficients of variation)')
cv_panel = build_panel('cv')
if (!every_year(cv_panel)) {
  stop('table_01_cv: an industry is missing from at least one year')
}

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

dir.create(file.path(dest, 'aligned'), recursive = TRUE, showWarnings = FALSE)
for (out in list(list(id = 'table_01', p = panel),
                 list(id = 'table_01_cv', p = cv_panel))) {
  out_path = file.path(dest, 'aligned', paste0(out$id, '.csv'))
  write.csv(out$p, out_path, row.names = FALSE, na = '')
  message(sprintf('%s: wrote %s (%d rows; %d industries, %d items, %d years)',
                  out$id, out_path, nrow(out$p),
                  length(unique(out$p$industry)), length(unique(out$p$item)),
                  n_years))
}
