#!/usr/bin/env Rscript
#------------------------------------------------------------------------------
# align_tables.R
#
# Extends the cross-year alignment beyond Table 4 (see align_table4.R):
#
# 1) MODERN PANELS -- every 2014+ basic table, generic long format
#    aligned/modern/{table_id}.csv
#      tax_year, row_seq, section, row_label, row_indent, col_seq,
#      col_label, col_group, value, flag, unit
#    Rows/columns carry the published labels (normalized: footnote refs,
#    dot leaders, and whitespace wraps stripped), so a (row_label, col_label)
#    pair keys the same cell across years. row_indent (stub leading spaces)
#    and col_group (merged-cell industry spanners) carry the hierarchy of
#    the industry tables -- see extract_sheet. aligned/modern/_coverage.csv
#    records which labels appear in which years -- label drift (e.g. NAICS
#    revisions in the industry tables, the Table 13 definition change in
#    2017) shows up there instead of failing silently.
#
# 2) DEEP PANELS 1994-2022 -- the crosswalk pairs whose row AND column
#    dimensions are stable text labels (items x size classes), aligned the
#    whole way back like Table 4:
#      modern Table 2.1 <- old Table 2 (balance sheet etc., by asset size)
#      modern Table 2.2 <- old Table 3 (same, returns with net income)
#      modern Table 3.1 <- old Table 5 (selected items, by receipt size)
#    aligned/table_02_1.csv, aligned/table_02_2.csv, aligned/table_03_1.csv
#      tax_year, item, col_type (total | zero_assets | size_class),
#      size_class, class_lo, class_hi, value, flag, unit
#    Size-class BRACKETS changed across eras (finer small-asset classes in
#    the 1990s) -- the panel keeps each year's published classes; 'total'
#    and 'zero_assets' columns are continuous throughout. Item labels are
#    harmonized via ITEM_ALIASES (curated from the coverage report).
#
#    The industry-dimension tables (1, 5.x, 6.x, 7, 10-12) are NOT extended
#    past 2014 here: their industry classification crosses SIC->NAICS (1998)
#    and NAICS revisions, which needs a per-industry concordance, not label
#    matching. See notes/modern_tables.md.
#
# Usage:
#   Rscript align_tables.R [--dest /path/to/store]
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

MODERN_YEARS = 2014:2022

# Tables where rows are industries (unit inferred from the column instead
# of the row) and tables published as percentages
ROW_IS_INDUSTRY = c('table_01', 'table_01_cv')
PCT_TABLES      = c('table_02_1a', 'table_02_4a')

#--------------------------
# Per-cell units
#--------------------------

cell_unit = function(table_id, row_label, col_label) {
  if (table_id == 'table_01_cv')     return('cv_pct')
  if (table_id %in% PCT_TABLES)      return('pct')
  if (table_id %in% ROW_IS_INDUSTRY) {
    return(ifelse(grepl('number of', tolower(col_label)), 'count',
                  'thousand_usd'))
  }
  ifelse(grepl('^number of|^total number of', tolower(row_label)), 'count',
         'thousand_usd')
}

#--------------------------------
# 1) Modern panels, all tables
#--------------------------------

modern_ids = basename(list.dirs(file.path(dest, 'modern'), recursive = FALSE))
dir.create(file.path(dest, 'aligned', 'modern'), recursive = TRUE,
           showWarnings = FALSE)

coverage = list()
for (id in modern_ids) {
  panels = list()
  for (year in MODERN_YEARS) {
    path = file.path(dest, 'modern', id, sprintf('%s_%d.xlsx', id, year))
    if (!file.exists(path)) next   # e.g. table_14 before 2015
    df = extract_sheet(path, script_dir)
    df = cbind(tax_year = year, df)
    df$unit = cell_unit(id, df$row_label, df$col_label)
    panels[[as.character(year)]] = df
  }
  panel = do.call(rbind, panels)
  out_path = file.path(dest, 'aligned', 'modern', paste0(id, '.csv'))
  write.csv(panel, out_path, row.names = FALSE, na = '')

  n_years = length(panels)
  for (dim_name in c('row_label', 'col_label')) {
    tab = table(unique(panel[, c('tax_year', dim_name)])[[dim_name]])
    coverage[[paste(id, dim_name)]] = data.frame(
      table_id = id, dim = sub('_label', '', dim_name),
      label = names(tab), n_years = as.integer(tab), years_available = n_years,
      row.names = NULL, stringsAsFactors = FALSE
    )
  }
  stable_r = sum(coverage[[paste(id, 'row_label')]]$n_years == n_years)
  total_r  = nrow(coverage[[paste(id, 'row_label')]])
  stable_c = sum(coverage[[paste(id, 'col_label')]]$n_years == n_years)
  total_c  = nrow(coverage[[paste(id, 'col_label')]])
  message(sprintf('%-12s %d years  rows stable %3d/%3d  cols stable %3d/%3d',
                  id, n_years, stable_r, total_r, stable_c, total_c))
}
cov = do.call(rbind, coverage)
cov = cov[order(cov$table_id, cov$dim, cov$n_years, cov$label), ]
write.csv(cov, file.path(dest, 'aligned', 'modern', '_coverage.csv'),
          row.names = FALSE)
message('Wrote aligned/modern/ panels + _coverage.csv')

#---------------------------------------------
# 2) Deep panels: 2.1 <- 2, 2.2 <- 3, 3.1 <- 5
#---------------------------------------------

# Old-numbering filename lineages (same scheme as Table 22 -> Table 4)
old_file = function(tbl, year) {
  yy = sprintf('%02d', year %% 100)
  if (year >= 2004) return(sprintf('archive/%d/%sco%02dccr.xls', year, yy, tbl))
  if (year >= 1998) return(sprintf('archive/%d/%sco%02dnr.xls',  year, yy, tbl))
  if (year == 1997) return(sprintf('archive/1997/TABL%d.XLS',    tbl))
  if (year == 1996) return(sprintf('archive/1996/CRTB%02d.XLS',  tbl))
  if (year == 1995) return(sprintf('archive/1995/CRTAB%02d.XLS', tbl))
  suffix = if (tbl == 5) 'BR' else 'TA'
  sprintf('archive/1994/94CO%02d%s.XLS', tbl, suffix)
}

# class_mult: the 2014+ Tables 2.1/2.2 state asset-class bounds in THOUSANDS
# of dollars ("$1 under $500" = $1 under $500,000, per their footnote); all
# other vintages use whole dollars. truncate: old Table 5 repeats its item
# block per sector -- keep only the leading All-Industries block by cutting
# at the first sector header.
DEEP_SPECS = list(
  list(modern_id = 'table_02_1', old_tbl = 2,
       span = c('size of total assets'),
       class_mult = function(year) if (year >= 2014) 1000 else 1,
       truncate = NULL),
  list(modern_id = 'table_02_2', old_tbl = 3,
       span = c('size of total assets'),
       class_mult = function(year) if (year >= 2014) 1000 else 1,
       truncate = NULL),
  list(modern_id = 'table_03_1', old_tbl = 5,
       span = c('size of business receipts'),
       class_mult = function(year) 1,
       truncate = function(year) if (year <= 2013) '^agriculture' else NULL)
)

# Label drift harmonization across eras (variant -> canonical, canonical
# being the modern label where one exists). Curated from the coverage
# report; each cross-era merge was verified by value continuity at the seam
# (e.g. "rents" $160.2B in 2013 -> "gross rents" $174.6B in 2014, and
# "income tax, total" 1994 = $172.8B matches Table 4's before-credits total).
ITEM_ALIASES = c(
  'number of returns, total'        = 'number of returns',
  'loans to stockholders'           = 'loans to shareholders',
  'loans from stockholders'         = 'loans from shareholders',
  'contributions or gifts'          = 'charitable contributions',
  'income tax, total'               = 'total income tax before credits',
  'income tax after credits'        = 'total income tax after credits',
  'investments in government obligations' = 'u.s. government obligations',
  'notes and accounts receivable'   = 'trade notes and accounts receivable',
  'taxes paid'                      = 'taxes and licenses',
  'rents'                           = 'gross rents',
  'royalties'                       = 'gross royalties',
  'rent paid on business property'  = 'rents paid',
  'repairs'                         = 'repairs and maintenance',

  'mortgages, notes, and bonds payable in less than one year' =
    'mortgages, notes, bonds payable in less than 1 year',
  'mortgages,notes,and bonds payable in less than one year' =
    'mortgages, notes, bonds payable in less than 1 year',
  'mortgages, notes, and bonds under one year' =
    'mortgages, notes, bonds payable in less than 1 year',
  'mortgages, notes, and bonds payable in one year or more' =
    'mortgages, notes, bonds payable in 1 year or more',
  'mortgages,notes,and bonds payable in one year or more' =
    'mortgages, notes, bonds payable in 1 year or more',
  'mortgages, notes, bonds, one year or more' =
    'mortgages, notes, bonds payable in 1 year or more',

  'net long-term capital gain reduced by net short-term capital loss' =
    'net long-term capital gain less net short-term loss',
  'net l-t capital gain less net s-t loss' =
    'net long-term capital gain less net short-term loss',
  'net l-t capital gain less net st loss' =
    'net long-term capital gain less net short-term loss',
  'net short-term capital gain reduced by net long-term capital loss' =
    'net short-term capital gain less net long-term loss',
  'net short-term-capital gain reduced by net long-term capital loss' =
    'net short-term capital gain less net long-term loss',
  'net s-t capital gain less net l-t loss' =
    'net short-term capital gain less net long-term loss',
  'net s-t capital gain less net lt loss' =
    'net short-term capital gain less net long-term loss',

  'pension, profit-sharing, stock bonus, and annuity plans' =
    'pension, profit-sharing, etc., plans',
  'pension, profit-sharing, stock, annuity' =
    'pension, profit-sharing, etc., plans',
  'pension, profit sharing, stock, annuity' =
    'pension, profit-sharing, etc., plans',

  'interest on govt. obligations, total' =
    'interest on government obligations, total',
  'u.s. govt. obligations, total' =
    'u.s. government obligations, total',
  'interest on government obligations: state, local' =
    'interest on government obligations: state and local',
  # 1994-2003 Table 5 wraps one combined asset item over two stub lines; the
  # data sits on the second line ("securities, and other current assets")
  'securities, and other current assets' =
    'cash, govt. obligations, tax-exempt securities, and other current assets'
)

apply_alias = function(label) {
  key = tolower(label)
  ifelse(key %in% names(ITEM_ALIASES), unname(ITEM_ALIASES[key]), key)
}

deep_extract = function(path, spec, year) {
  df = extract_sheet(path, script_dir)
  trunc = if (is.null(spec$truncate)) NULL else spec$truncate(year)
  if (!is.null(trunc)) {
    # keep only the leading (All-Industries) item block of sectioned tables
    cut = df$row_seq[grepl(trunc, tolower(df$row_label)) |
                       grepl(trunc, tolower(ifelse(is.na(df$section), '',
                                                   df$section)))]
    if (length(cut) > 0) df = df[df$row_seq < min(cut), ]
  }
  hdr = unique(df[, c('col_seq', 'col_label')])
  parsed = lapply(hdr$col_label, parse_class_header, span_phrases = spec$span)
  bad = which(vapply(parsed, is.null, logical(1)))
  if (length(bad) > 0) {
    stop(path, ': unrecognized size-class column header(s): ',
         paste(sprintf('"%s"', hdr$col_label[bad]), collapse = ', '))
  }
  # scale class bounds to whole dollars and build canonical labels AFTER
  # scaling, so "$1 under $500 [thousands]" and "$1 under $500,000" unify.
  # A published lower bound of $1 stays $1 (it marks "above zero").
  mult = spec$class_mult(year)
  fmt  = function(x) format(x, big.mark = ',', scientific = FALSE, trim = TRUE)
  cls = do.call(rbind, lapply(seq_len(nrow(hdr)), function(k) {
    p  = parsed[[k]]
    lo = if (!is.na(p$lo) && p$lo != 1) p$lo * mult else p$lo
    hi = if (!is.na(p$hi)) p$hi * mult else p$hi
    size_class =
      if (p$col_type != 'size_class') NA_character_
      else if (is.na(hi))             sprintf('$%s or more', fmt(lo))
      else                            sprintf('$%s under $%s', fmt(lo), fmt(hi))
    data.frame(col_seq = hdr$col_seq[k], col_type = p$col_type,
               size_class = size_class, class_lo = lo, class_hi = hi,
               stringsAsFactors = FALSE)
  }))
  if (sum(cls$col_type == 'total') != 1) {
    stop(path, ': expected exactly one total column')
  }
  df = merge(df, cls, by = 'col_seq')
  df$item = apply_alias(df$row_label)
  if (anyDuplicated(df[, c('item', 'col_type', 'size_class')])) {
    dup = df[duplicated(df[, c('item', 'col_type', 'size_class')]), ]
    stop(path, ': duplicate item x class cells, e.g. "', dup$item[1], '"')
  }
  df$unit = ifelse(grepl('^number of', df$item), 'count', 'thousand_usd')
  data.frame(tax_year = year,
             df[order(df$row_seq, df$col_seq),
                c('item', 'col_type', 'size_class', 'class_lo', 'class_hi',
                  'value', 'flag', 'unit')],
             row.names = NULL, stringsAsFactors = FALSE)
}

for (spec in DEEP_SPECS) {
  panels = list()
  for (year in 1994:2022) {
    path = file.path(dest, if (year >= 2014) {
      sprintf('modern/%s/%s_%d.xlsx', spec$modern_id, spec$modern_id, year)
    } else {
      old_file(spec$old_tbl, year)
    })
    if (!file.exists(path)) stop('missing input: ', path)
    panels[[as.character(year)]] = deep_extract(path, spec, year)
  }
  panel = do.call(rbind, panels)

  # continuity check on the total column: number of returns must be present
  # and positive in every year
  nret = panel[panel$col_type == 'total' & panel$item == 'number of returns', ]
  if (nrow(nret) != 29 || any(is.na(nret$value)) || any(nret$value <= 0)) {
    stop(spec$modern_id, ': number-of-returns total column broken')
  }

  out_path = file.path(dest, 'aligned', paste0(spec$modern_id, '.csv'))
  write.csv(panel, out_path, row.names = FALSE, na = '')
  n_stable = sum(table(unique(panel[, c('tax_year', 'item')])$item) == 29)
  message(sprintf('%s: wrote %s (%d rows; %d items in all 29 years, %d total items)',
                  spec$modern_id, out_path, nrow(panel), n_stable,
                  length(unique(panel$item))))
}
