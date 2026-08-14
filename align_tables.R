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
# 2) DEEP PANELS -- the crosswalk pairs whose row AND column dimensions are
#    stable text labels (items x classes), aligned the whole way back:
#      table_02_1  <- old 2         balance sheet etc. by asset size  1994-2022
#      table_02_2  <- old 3         same, returns with net income     1994-2022
#      table_03_1  <- old 5         selected items by receipt size    1994-2022
#      table_03_2  <- old 1120S 4   Form 1120S by receipt size        2004-2022
#      table_09    <- old 1120S 6   Form 1120S by shareholder count   2004-2022
#      tax_year, item, col_type (total | zero_assets | size_class |
#      count_class), size_class, class_lo, class_hi, value, flag, unit
#    Class BRACKETS changed across eras (finer small-asset classes in the
#    1990s) -- the panel keeps each year's published classes; 'total' (and
#    'zero_assets') are the continuous columns. Item labels are harmonized via
#    ITEM_ALIASES, and the 1120S stub additionally via S_ITEM_ALIASES and its
#    split rows (both in alignment_helpers.R).
#
#    The industry-dimension tables are aligned in align_industry.R instead --
#    they need a canonical sector list rather than label matching. Run that
#    script FIRST if you want the 1120S cross-check at the end of this one,
#    which tests table_03_2 and table_09 against table_07's totals.
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

# Old-numbering filename lineages (same scheme as Table 22 -> Table 4). The
# 1120S companions are a scheme of their own and a much shorter, gappier span:
# '{yy}co1120s{NN}.xls' in TY2004, NOTHING in TY2005 (that year's zip omits the
# 1120S set), then '{yy}co{NN}s.xls' for TY2006-2013 with TY2008 missing these
# two tables -- hence the per-spec `years`.
old_file = function(spec, year) {
  yy = sprintf('%02d', year %% 100)
  tbl = spec$old_tbl
  if (isTRUE(spec$s_stub)) {
    if (year >= 2006) return(sprintf('archive/%d/%sco%02ds.xls', year, yy, tbl))
    return(sprintf('archive/%d/%sco1120s%02d.xls', year, yy, tbl))
  }
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
# other vintages use whole dollars. truncate: old Tables 5 and 1120S 4 repeat
# their item block per sector -- keep only the leading All-Industries block by
# cutting at the first sector header. class_kind: Table 9 classifies by a
# COUNT of shareholders rather than a money amount. s_stub: the 1120S item
# stub carries its own renames and split rows (see alignment_helpers.R).
DEEP_SPECS = list(
  list(modern_id = 'table_02_1', old_tbl = 2, years = 1994:2022,
       span = c('size of total assets'), class_kind = 'dollars',
       class_mult = function(year) if (year >= 2014) 1000 else 1,
       truncate = NULL, s_stub = FALSE),
  list(modern_id = 'table_02_2', old_tbl = 3, years = 1994:2022,
       span = c('size of total assets'), class_kind = 'dollars',
       class_mult = function(year) if (year >= 2014) 1000 else 1,
       truncate = NULL, s_stub = FALSE),
  list(modern_id = 'table_03_1', old_tbl = 5, years = 1994:2022,
       span = c('size of business receipts'), class_kind = 'dollars',
       class_mult = function(year) 1,
       truncate = function(year) if (year <= 2013) '^agriculture' else NULL,
       s_stub = FALSE),

  list(modern_id = 'table_03_2', old_tbl = 4,
       years = c(2004, 2006:2007, 2009:2022),
       span = c('size of business receipts', 'sector and item'),
       class_kind = 'dollars', class_mult = function(year) 1,
       truncate = function(year) if (year <= 2013) '^agriculture' else NULL,
       s_stub = TRUE),
  list(modern_id = 'table_09', old_tbl = 6,
       years = c(2004, 2006:2007, 2009:2022),
       span = c('number of shareholders'), class_kind = 'count',
       class_mult = function(year) 1, truncate = NULL, s_stub = TRUE)
)

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
  parser = if (spec$class_kind == 'count') parse_count_header else parse_class_header
  parsed = lapply(hdr$col_label, parser, span_phrases = spec$span)
  bad = which(vapply(parsed, is.null, logical(1)))
  if (length(bad) > 0) {
    stop(path, ': unrecognized ', spec$class_kind, '-class column header(s): ',
         paste(sprintf('"%s"', hdr$col_label[bad]), collapse = ', '))
  }
  # scale class bounds to whole dollars and build canonical labels AFTER
  # scaling, so "$1 under $500 [thousands]" and "$1 under $500,000" unify.
  # A published lower bound of $1 stays $1 (it marks "above zero"). Count
  # classes take no scaling and read as the published range.
  mult = spec$class_mult(year)
  fmt  = function(x) format(x, big.mark = ',', scientific = FALSE, trim = TRUE)
  cls = do.call(rbind, lapply(seq_len(nrow(hdr)), function(k) {
    p  = parsed[[k]]
    lo = if (!is.na(p$lo) && p$lo != 1) p$lo * mult else p$lo
    hi = if (!is.na(p$hi)) p$hi * mult else p$hi
    size_class =
      if (p$col_type == 'total' || p$col_type == 'zero_assets') NA_character_
      else if (p$col_type == 'count_class') {
        if (is.na(hi))       sprintf('%s or more', fmt(lo))
        else if (lo == hi)   fmt(lo)
        else                 sprintf('%s-%s', fmt(lo), fmt(hi))
      }
      else if (is.na(hi))    sprintf('$%s or more', fmt(lo))
      else                   sprintf('$%s under $%s', fmt(lo), fmt(hi))
    data.frame(col_seq = hdr$col_seq[k], col_type = p$col_type,
               size_class = size_class, class_lo = lo, class_hi = hi,
               stringsAsFactors = FALSE)
  }))
  if (sum(cls$col_type == 'total') != 1) {
    stop(path, ': expected exactly one total column')
  }
  # resolve the stub in PUBLISHED ROW ORDER -- qualify_splits reads upwards
  # for each split row's parent -- then map back onto the long frame
  stub = unique(df[, c('row_seq', 'row_label')])
  stub = stub[order(stub$row_seq), ]
  stub$item = apply_alias(stub$row_label)
  if (spec$s_stub) stub$item = qualify_splits(apply_s_alias(stub$item))
  df = merge(df, cls, by = 'col_seq')
  df$item = stub$item[match(df$row_seq, stub$row_seq)]
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

deep_panels = list()
for (spec in DEEP_SPECS) {
  panels = list()
  for (year in spec$years) {
    path = file.path(dest, if (year >= 2014) {
      sprintf('modern/%s/%s_%d.xlsx', spec$modern_id, spec$modern_id, year)
    } else {
      old_file(spec, year)
    })
    if (!file.exists(path)) stop('missing input: ', path)
    panels[[as.character(year)]] = deep_extract(path, spec, year)
  }
  panel = do.call(rbind, panels)

  # continuity check on the total column: number of returns must be present
  # and positive in every year
  n_years = length(spec$years)
  nret = panel[panel$col_type == 'total' & panel$item == 'number of returns', ]
  if (nrow(nret) != n_years || any(is.na(nret$value)) || any(nret$value <= 0)) {
    stop(spec$modern_id, ': number-of-returns total column broken')
  }

  # Class detail must add to the total column, the same guard the industry
  # panels use. Skipped where a component is suppressed, and where the classes
  # OVERLAP: 1994-2003 Table 5 publishes an "Under $100,000" subtotal beside
  # its own finer sub-classes, so its parts are not a partition.
  #
  # A gap must clear a relative AND an absolute floor. A dozen-odd class cells
  # each rounded to the nearest thousand drift a unit or two against the
  # published total: measured over the 3,227 testable combinations in
  # table_02_1 and table_03_1 the gap never exceeds THREE, and its median is
  # one. Five therefore sits just above the rounding ceiling and far below any
  # structural error, which lands in the percent range.
  CLASS_ABS_TOL = 5
  class_gaps = function(panel) {
    gaps = list()
    for (year in spec$years) {
      p = panel[panel$tax_year == year, ]
      overlapping = any(duplicated(unique(p[p$col_type != 'total',
                                            c('class_lo', 'class_hi')])$class_lo))
      if (overlapping) next
      for (item in unique(p$item)) {
        pi = p[p$item == item, ]
        parts = pi$value[pi$col_type != 'total']
        total = pi$value[pi$col_type == 'total']
        if (length(total) != 1 || anyNA(parts) || is.na(total) || total == 0) next
        gaps[[length(gaps) + 1]] = data.frame(
          tax_year = year, item = item,
          abs_gap = abs(sum(parts) - total),
          rel_gap = abs(sum(parts) - total) / abs(total))
      }
    }
    g = do.call(rbind, gaps)
    g[order(-g$rel_gap), ]
  }
  fails = function(g) g[g$rel_gap > 1e-4 & g$abs_gap > CLASS_ABS_TOL, ]
  g = class_gaps(panel)

  # SOI published the 1120S files for TY2007 and TY2009 with every minus sign
  # stripped (see notes/industry_tables.md). In the industry panels the sector
  # identity localizes the loss well enough to repair most of it, because there
  # are 21 components and a corroborating second table. Neither holds across a
  # dozen size classes with nothing to check them against, so here an item that
  # fails to reconcile in one of those two vintages is WITHDRAWN rather than
  # reconstructed: value NA, flag 'unsigned', and each one named below.
  UNSIGNED_YEARS = c(2007, 2009)
  if (spec$s_stub) {
    drop = fails(g)
    drop = drop[drop$tax_year %in% UNSIGNED_YEARS, ]
    for (k in seq_len(nrow(drop))) {
      hit = panel$tax_year == drop$tax_year[k] & panel$item == drop$item[k]
      panel$value[hit] = NA_real_
      panel$flag[hit] = 'unsigned'
      message(sprintf('  %s: withheld %d cells of "%s" in %d (published unsigned, %.2f%% out)',
                      spec$modern_id, sum(hit), drop$item[k], drop$tax_year[k],
                      100 * drop$rel_gap[k]))
    }
    if (nrow(drop) > 0) g = class_gaps(panel)
  }

  bad = fails(g)
  if (nrow(bad) > 0) {
    stop(sprintf('%s: class detail does not add to the total:\n%s',
                 spec$modern_id,
                 paste(sprintf('  %d %s (%.3f%%)', bad$tax_year, bad$item,
                               100 * bad$rel_gap), collapse = '\n')))
  }
  material = g[g$abs_gap > CLASS_ABS_TOL, ]
  deep_panels[[spec$modern_id]] = panel

  out_path = file.path(dest, 'aligned', paste0(spec$modern_id, '.csv'))
  write.csv(panel, out_path, row.names = FALSE, na = '')
  n_stable = sum(table(unique(panel[, c('tax_year', 'item')])$item) == n_years)
  message(sprintf('%s: wrote %s (%d rows; %d items in all %d years %d-%d, %d total items)',
                  spec$modern_id, out_path, nrow(panel), n_stable, n_years,
                  min(spec$years), max(spec$years), length(unique(panel$item))))
  message(sprintf('%s class sums: %d year x item combinations, %s',
                  spec$modern_id, nrow(g),
                  if (nrow(material) == 0) {
                    sprintf('every gap within the %d-unit rounding floor',
                            CLASS_ABS_TOL)
                  } else {
                    sprintf('worst relative gap %.2e (%d %s)', material$rel_gap[1],
                            material$tax_year[1], material$item[1])
                  }))
}

# The two 1120S deep panels classify the same universe as the 1120S industry
# panels, so their totals must match those of table_07 (income items) and
# table_06_1 (balance sheet) industry by industry -- checked here on the two
# counts both publish.
s_totals = function(id, item) {
  p = deep_panels[[id]]
  q = p[p$col_type == 'total' & p$item == item, ]
  setNames(q$value, q$tax_year)
}
t07_path = file.path(dest, 'aligned', 'table_07.csv')
if (!file.exists(t07_path)) {
  message('table_07 panel not built yet -- run align_industry.R to enable the ',
          '1120S cross-check')
}
ind = if (file.exists(t07_path)) {
  p = read.csv(t07_path, colClasses = c(value = 'numeric'))
  p[p$row_type == 'all_industries', ]
} else NULL
for (id in if (is.null(ind)) character(0) else c('table_03_2', 'table_09')) {
  for (item in c('number of returns', 'number of shareholders')) {
    a = s_totals(id, item)
    b = setNames(ind$value[ind$item == item], ind$tax_year[ind$item == item])
    b = b[names(a)]
    ok = !is.na(a) & !is.na(b) & b != 0
    # the modern tables publish weighted counts with a fractional part, and
    # the two tables round them differently, so compare relatively
    rel = abs(a[ok] - b[ok]) / abs(b[ok])
    if (any(rel > 1e-5)) {
      i = which(ok)[which(rel > 1e-5)[1]]
      stop(sprintf('%s and table_07 disagree on %s in %s: %.2f vs %.2f',
                   id, item, names(a)[i], a[i], b[i]))
    }
    message(sprintf('%s total column agrees with table_07 on %s: %d years, worst relative gap %.2e',
                    id, item, sum(ok), max(rel)))
  }
}
