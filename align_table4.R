#!/usr/bin/env Rscript
#------------------------------------------------------------------------------
# align_table4.R
#
# Builds a harmonized 1994-2022 panel of Corporation Complete Report (Pub 16)
# Table 4 -- "Returns with Total Income Tax after Credits, other than Forms
# 1120S, 1120-REIT, and 1120-RIC: Number of Returns and Selected Tax Items,
# by Size of Total Income Tax After Credits". In the 1994-2013 publications
# this is Table 22 (see docs/table_crosswalk_2014.pdf).
#
# Reads the raw files that download_irs_corp.R placed under the destination
# (archive/{year}/ and modern/table_04/) and writes one long CSV:
#
#   aligned/table_4.csv    tax_year, row_type, size_class, class_lo,
#                          variable, unit, value, flag
#
# Row types (see notes/table4.md for why this matters):
#   size_class               the 15 size-of-tax classes -- IDENTICAL brackets
#                            across all years, 1994-2022
#   with_tax_after_credits   subtotal the classes add to. In 1994-2013 this is
#                            an explicit row below "Total"; in 2014+ the
#                            table's "Total" row IS this concept
#   total_active, with_net_income, without_net_income,
#   with_tax_before_credits  published 1994-2013 only (the old table also
#                            covered active corporations with zero tax after
#                            credits; the modern table does not)
#
# Variables (columns) by era -- canonical names, mapped in vars_for_year():
#   all years : n_returns, income_subject_to_tax, tax_before_credits,
#               income_tax (labeled "Regular tax" 1994-95), foreign_tax_credit,
#               general_business_credit, tax_after_credits
#   1994-2013 : + prior_year_min_tax_credit
#   1994-2006 : + us_possessions_tax_credit
#   1994-2005 : + nonconv_fuel_credit
#   1994 only : + orphan_drug_credit
#
# Units: money amounts in THOUSANDS of dollars; size-class bounds and
# n_returns in whole units. Flags: 'd' = suppressed (value NA), '*' = use
# with caution / few returns, '-' = none reported (value 0), 'blank' = empty
# cell in a data row (value NA).
#
# The 1994-2002 .xls files (except 1996) are BIFF4, unreadable by readxl;
# those are read via read_biff4.py (python3 + xlrd, see README).
#
# Usage:
#   Rscript align_table4.R                       # reads/writes under ./data
#   Rscript align_table4.R --dest /path/to/store
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
YEARS = 1994:2022

#---------------------------------------
# Where Table 4 / old Table 22 lives
#---------------------------------------

# The archive filename for Table 22 changed scheme several times
table4_path = function(year) {
  yy = sprintf('%02d', year %% 100)
  f = if (year >= 2014)      sprintf('modern/table_04/table_04_%d.xlsx', year)
  else if (year >= 2004)     sprintf('archive/%d/%sco22ccr.xls', year, yy)
  else if (year >= 1998)     sprintf('archive/%d/%sco22nr.xls',  year, yy)
  else if (year == 1997)     'archive/1997/TABL22.XLS'
  else if (year == 1996)     'archive/1996/CRTB22.XLS'
  else if (year == 1995)     'archive/1995/CRTAB22.XLS'
  else                       'archive/1994/94CO22AC.XLS'
  f
}

# Canonical variable names, in published column order, per year
vars_for_year = function(year) {
  if (year == 1994) return(c(
    'n_returns', 'income_subject_to_tax', 'tax_before_credits', 'income_tax',
    'foreign_tax_credit', 'us_possessions_tax_credit', 'orphan_drug_credit',
    'nonconv_fuel_credit', 'general_business_credit',
    'prior_year_min_tax_credit', 'tax_after_credits'))
  if (year <= 2005) return(c(
    'n_returns', 'income_subject_to_tax', 'tax_before_credits', 'income_tax',
    'foreign_tax_credit', 'us_possessions_tax_credit', 'nonconv_fuel_credit',
    'general_business_credit', 'prior_year_min_tax_credit',
    'tax_after_credits'))
  if (year == 2006) return(c(
    'n_returns', 'income_subject_to_tax', 'tax_before_credits', 'income_tax',
    'foreign_tax_credit', 'us_possessions_tax_credit',
    'general_business_credit', 'prior_year_min_tax_credit',
    'tax_after_credits'))
  if (year <= 2013) return(c(
    'n_returns', 'income_subject_to_tax', 'tax_before_credits', 'income_tax',
    'foreign_tax_credit', 'general_business_credit',
    'prior_year_min_tax_credit', 'tax_after_credits'))
  c('n_returns', 'income_subject_to_tax', 'tax_before_credits', 'income_tax',
    'foreign_tax_credit', 'general_business_credit', 'tax_after_credits')
}

# Column-header keyword used to verify each mapped column against the file
HEADER_CHECK = c(
  n_returns                 = 'number of[\\s]+returns',
  income_subject_to_tax     = 'subject',
  tax_before_credits        = 'before[\\s]+cr',
  income_tax                = '(income|regular)[\\s]+tax',
  foreign_tax_credit        = 'foreign',
  us_possessions_tax_credit = 'possessions',
  orphan_drug_credit        = 'orphan',
  nonconv_fuel_credit       = 'fuel',
  general_business_credit   = 'business',
  prior_year_min_tax_credit = 'minimum',
  tax_after_credits         = 'after'
)

MONEY_UNIT = 'thousand_usd'
UNITS = c(
  n_returns                 = 'returns',
  income_subject_to_tax     = MONEY_UNIT,
  tax_before_credits        = MONEY_UNIT,
  income_tax                = MONEY_UNIT,
  foreign_tax_credit        = MONEY_UNIT,
  us_possessions_tax_credit = MONEY_UNIT,
  orphan_drug_credit        = MONEY_UNIT,
  nonconv_fuel_credit       = MONEY_UNIT,
  general_business_credit   = MONEY_UNIT,
  prior_year_min_tax_credit = MONEY_UNIT,
  tax_after_credits         = MONEY_UNIT
)

#---------------------
# Locate table pieces
#---------------------

check_headers = function(m, numrow, cols, vars, path) {
  for (k in seq_along(cols)) {
    hdr = tolower(paste(m[seq_len(numrow - 1), cols[k]], collapse = ' '))
    hdr = gsub('\\s+', ' ', hdr)   # headers wrap across lines within cells
    if (!grepl(HEADER_CHECK[[vars[k]]], hdr, perl = TRUE)) {
      stop(sprintf('%s: column %d header does not look like "%s": "%s"',
                   path, k, vars[k], trimws(hdr)))
    }
  }
}

classify_row = function(label, year) {
  l = tolower(label)
  if (l == 'total') {
    # In 1994-2013 "Total" spans ALL active non-S/REIT/RIC corporations
    # (including zero tax after credits); the 2014+ table only covers
    # returns WITH tax after credits, so its "Total" is the old subtotal
    if (year >= 2014) return('with_tax_after_credits')
    return('total_active')
  }
  if (grepl('^returns with net income', l))       return('with_net_income')
  if (grepl('^returns without net income', l))    return('without_net_income')
  if (grepl('^returns with total income tax before', l))
    return('with_tax_before_credits')
  if (grepl('^returns with total income tax after', l))
    return('with_tax_after_credits')
  if (grepl('^\\$', l))                           return('size_class')
  NA_character_
}

# "$6,000 under $10,000" -> 6000; "$100,000,000 or more" -> 1e8
class_lower_bound = function(label) {
  as.numeric(gsub('[$,]', '', regmatches(label, regexpr('^\\$[0-9,]+', label))))
}

#--------------------
# Parse one vintage
#--------------------

parse_year = function(year) {
  path = file.path(dest, table4_path(year))
  if (!file.exists(path)) {
    stop('missing input (run download_irs_corp.R first): ', path)
  }
  m    = read_sheet_matrix(path, script_dir)
  vars = vars_for_year(year)
  loc  = find_numrow(m)
  if (is.null(loc)) stop(path, ': column-number row not found')
  if (length(loc$cols) != length(vars)) {
    stop(sprintf('%s: expected %d data columns, found %d',
                 path, length(vars), length(loc$cols)))
  }
  check_headers(m, loc$row, loc$cols, vars, path)

  label_cols = seq_len(min(loc$cols) - 1)
  out = list()
  for (i in (loc$row + 1):nrow(m)) {
    lab_cells = m[i, label_cols]
    label = normalize_label(lab_cells[lab_cells != ''][1])
    cells = m[i, loc$cols]
    if (is.na(label)) label = ''
    row_type = if (label == '') NA_character_ else classify_row(label, year)
    if (is.na(row_type)) {
      # spacer, section-header, or footnote row: legitimate only if empty
      # of data; anything else means the layout changed -> fail loudly.
      # Footnote rows can spill long text into data columns, so treat rows
      # whose cells contain no digits as empty too.
      if (any(grepl('^[0-9*,.$ -]*[0-9]', cells)) &&
          !grepl('^(notes?:|source:|\\*|d -|\\[)', tolower(label))) {
        stop(sprintf('%s row %d: unexpected labeled data row "%s"',
                     path, i, label))
      }
      next
    }
    cleaned = lapply(cells, clean_value)
    # all-blank rows are label wrap-arounds or footnote lines whose text
    # happens to start like a row label (e.g. "[17] Returns without net
    # income include ..." after footnote-marker stripping) -- not data
    if (all(vapply(cleaned, function(v) identical(v$flag, 'blank'),
                   logical(1)))) next
    out[[length(out) + 1]] = data.frame(
      tax_year   = year,
      row_type   = row_type,
      size_class = if (row_type == 'size_class') label else NA_character_,
      class_lo   = if (row_type == 'size_class') class_lower_bound(label)
                   else NA_real_,
      variable   = vars,
      unit       = unname(UNITS[vars]),
      value      = unname(vapply(cleaned, function(v) v$value, numeric(1))),
      flag       = unname(vapply(cleaned, function(v) v$flag,  character(1))),
      row.names  = NULL,
      stringsAsFactors = FALSE
    )
  }
  df = do.call(rbind, out)

  # structural checks: all 15 size classes, exactly one subtotal row
  n_classes = length(unique(df$size_class[df$row_type == 'size_class']))
  if (n_classes != 15) {
    stop(path, ': expected 15 size classes, found ', n_classes)
  }
  if (sum(df$row_type == 'with_tax_after_credits') != length(vars)) {
    stop(path, ': with_tax_after_credits subtotal row missing or duplicated')
  }
  for (rt in setdiff(unique(df$row_type), 'size_class')) {
    if (sum(df$row_type == rt) != length(vars)) {
      stop(path, ': row type "', rt, '" appears more than once')
    }
  }
  df
}

#------------------------------
# Build, check, write the panel
#------------------------------

panel = do.call(rbind, lapply(YEARS, parse_year))

# Size classes must add to the with_tax_after_credits subtotal (up to
# rounding; skip year x variable cells with suppressed/flagged detail)
for (year in YEARS) {
  for (v in vars_for_year(year)) {
    sub = panel[panel$tax_year == year & panel$variable == v, ]
    if (any(!is.na(sub$flag))) next
    detail   = sum(sub$value[sub$row_type == 'size_class'])
    subtotal = sub$value[sub$row_type == 'with_tax_after_credits']
    if (abs(detail - subtotal) > max(0.005 * abs(subtotal), 5)) {
      stop(sprintf('%d %s: size classes sum to %.0f but subtotal is %.0f',
                   year, v, detail, subtotal))
    }
  }
}

dir.create(file.path(dest, 'aligned'), recursive = TRUE, showWarnings = FALSE)
out_path = file.path(dest, 'aligned', 'table_4.csv')
write.csv(panel, out_path, row.names = FALSE, na = '')

message('Wrote ', out_path, ' (', nrow(panel), ' rows, ',
        length(YEARS), ' years)')
summary_tbl = do.call(rbind, lapply(YEARS, function(y) {
  sub = panel[panel$tax_year == y & panel$row_type == 'with_tax_after_credits', ]
  data.frame(year = y,
             returns_with_tax  = sub$value[sub$variable == 'n_returns'],
             tax_after_credits = sub$value[sub$variable == 'tax_after_credits'])
}))
message('Returns with tax after credits / total tax after credits ($k):')
invisible(apply(summary_tbl, 1, function(r) {
  message(sprintf('  %d  %10s  %14s', r['year'],
                  format(r['returns_with_tax'],  big.mark = ','),
                  format(r['tax_after_credits'], big.mark = ',')))
}))
