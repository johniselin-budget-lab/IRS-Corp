#------------------------------------------------------------------------------
# alignment_helpers.R
#
# Shared parsing machinery for the Corporation Complete Report aligners
# (align_table4.R, align_tables.R, align_industry.R). Everything here is
# table-agnostic: reading a sheet as a text matrix (with the BIFF4 python
# fallback), locating the column-number row(s) (including stacked lower
# panels), cleaning SOI cell values, normalizing labels, recovering the
# industry-spanner hierarchy from merged header cells, and the composite
# extract_sheet() that turns a published sheet into long rows.
#
# Sourced with `HELPER_DIR` pointing at this repo (for read_biff4.py /
# read_xls_merges.py).
#------------------------------------------------------------------------------

suppressMessages(library(readxl))

#-----------------------
# Read a sheet as text
#-----------------------

# trim = 'both' (default) trims cells on both sides; 'right' preserves
# LEADING whitespace, which carries the industry hierarchy in the Table 1
# family stubs (all eras, including the modern xlsx -- readxl's default
# trim_ws would silently destroy it).
#
# The read is anchored at A1. Left to itself readxl drops leading blank rows
# and columns, which would put the matrix out of step with the absolute
# coordinates sheet_merges() reads from the file -- the TY2004 Table 6 sheet
# opens with a blank row, and one row of drift is enough to blank the wrong
# header cells.
read_sheet_matrix = function(path, helper_dir, trim = 'both') {
  m = tryCatch({
    d = suppressWarnings(suppressMessages(
      read_excel(path, col_names = FALSE, col_types = 'text',
                 .name_repair = 'minimal', trim_ws = FALSE,
                 range = cell_limits(c(1, 1), c(NA, NA)))))
    as.matrix(d)
  }, error = function(e) NULL)
  if (is.null(m)) {
    # legacy BIFF4 file: go through python/xlrd
    if (Sys.which('python3') == '') {
      stop('python3 not found (needed for legacy .xls): ', path)
    }
    helper = file.path(helper_dir, 'read_biff4.py')
    lines = suppressWarnings(
      system2('python3', c(shQuote(helper), shQuote(path)),
              stdout = TRUE, stderr = TRUE))
    status = attr(lines, 'status')
    if (!is.null(status) && status != 0) {
      stop('read_biff4.py failed on ', path, ':\n',
           paste(lines, collapse = '\n'))
    }
    d = utils::read.csv(text = paste(lines, collapse = '\n'), header = FALSE,
                        colClasses = 'character')
    m = as.matrix(d)
  }
  m[is.na(m)] = ''
  if (trim == 'both') trimws(m) else sub('[ \t\r\n]+$', '', m)
}

#--------------------------------
# Locate the column-number row
#--------------------------------

# A strictly-increasing integer run, allowing the occasional skipped number
# (2014 Table 5.1 jumps 25 -> 27), which is what a column-number row is.
well_formed_run = function(run) {
  all(run == round(run)) && max(run) < 1000 && all(diff(run) >= 1) &&
    mean(diff(run) == 1) >= 0.9
}

# The run a candidate row carries, or NULL. "(1) (2) ..." written in
# accounting format arrives as -1 -2 ..., and a vintage may MIX the two
# conventions within one row (TY1998 Table 6 numbers its first printed panel
# 1..7 and the remaining ten -8..-92), so absolute values are the fallback.
numrow_run = function(v) {
  if (well_formed_run(v)) return(v)
  a = abs(v)
  if (well_formed_run(a)) return(a)
  NULL
}

# SOI marks data columns with a row of consecutive numbers under the header
# block: "1 2 3 ...", "(1) (2) ...", and in continuation tables the sequence
# starts above 1 (Table 1 part 2 numbers its columns 16, 17, ...).
# Returns list(row, cols) or NULL if the vintage has no such row (some
# early-2000s files) -- callers fall back to find_data_block().
find_numrow = function(m, max_scan = 30) {
  for (i in seq_len(min(max_scan, nrow(m)))) {
    v = suppressWarnings(as.numeric(gsub('^\\((.*)\\)$', '\\1', m[i, ])))
    idx = which(!is.na(v))
    if (length(idx) < 5) next
    # a stray print page number can sit in the stub ahead of the run -- the
    # TY2004 1120S Table 4 sheet opens this row with "221" -- so let the run
    # start a cell or two in, but only once it has failed to start at the first
    for (skip in 0:2) {
      cols = idx[seq_len(length(idx) - skip) + skip]
      if (length(cols) < 5) break
      run = numrow_run(v[cols])
      if (!is.null(run) && run[1] >= 1 && run[1] < 100) {
        return(list(row = i, cols = cols, vals = run))
      }
    }
  }
  NULL
}

# All column-number rows in a sheet. Old vintages stack a second block below
# the first in TWO different ways, told apart by how its column numbers run:
#
#   kind = 'cols'  numbering CONTINUES (prev_max + 1): the block holds further
#                  COLUMNS of the same rows -- 1996 Table 1 puts columns 1-20
#                  in rows 1-308 and repeats the title and stub below with
#                  columns numbered 21-40.
#   kind = 'rows'  numbering REPEATS the first block's: the sheet is paginated
#                  and the block holds further ROWS of the same columns -- the
#                  2001 Table 1 CV file prints columns 21-40 on four pages,
#                  each with its own title block, stub header and number row,
#                  carrying a different slice of industries.
#
# A continuation row must contain NOTHING but the number run (data rows never
# do). Returns a list of list(row, cols, vals, kind); empty if no numrow.
find_numrows = function(m) {
  first = find_numrow(m)
  if (is.null(first)) return(list())
  first$kind = 'cols'
  panels = list(first)
  i = first$row + 1
  while (i <= nrow(m)) {
    v = suppressWarnings(as.numeric(gsub('^\\((.*)\\)$', '\\1', m[i, ])))
    idx = unname(which(!is.na(v)))
    if (length(idx) >= 5 && identical(unname(which(m[i, ] != '')), idx)) {
      run = numrow_run(v[idx])
      prev = panels[[length(panels)]]$vals
      kind = if (is.null(run)) NA_character_
             else if (identical(run, first$vals)) 'rows'
             else if (run[1] == max(prev) + 1) 'cols'
             else NA_character_
      if (!is.na(kind)) {
        panels[[length(panels) + 1]] =
          list(row = i, cols = idx, vals = run, kind = kind)
      }
    }
    i = i + 1
  }
  panels
}

# Does a cell hold data (a number, 'd', or an SOI dash)?
looks_data_cell = function(x) {
  x = gsub('\\[[0-9]+\\]|[,*]', '', x)
  x != '' & (grepl('^\\(?-?[0-9.]+\\)?$', x) | tolower(x) == 'd' |
               grepl('^-+$', x))
}

# Fallback for vintages without a column-number row: anchor the first data
# row on its stub label, then keep the columns that actually carry data.
find_data_block = function(m, first_item_regex) {
  labels = tolower(m[, 1])
  first = which(grepl(first_item_regex, labels))[1]
  if (is.na(first)) stop('first data row (', first_item_regex, ') not found')
  body = m[first:nrow(m), , drop = FALSE]
  n_data = apply(body, 2, function(col) sum(looks_data_cell(col)))
  cols = which(n_data >= 5)
  cols = cols[cols > 1]   # never the stub column
  if (length(cols) < 3) stop('could not identify data columns')
  list(row = first - 1, cols = cols)   # 'row' plays the numrow role
}

#----------------------
# Labels and values
#----------------------

normalize_label = function(x) {
  # footnote refs, singly or in a list ("Total deductions [1,2]" in TY2018)
  x = gsub('\\[[0-9]+(\\s*,\\s*[0-9]+)*\\]', '', x)
  x = gsub('[.*]+$', '', trimws(x)) # trailing dot leaders / asterisks
  trimws(gsub('\\s+', ' ', x))
}

# One SOI cell -> list(value, flag). Money in thousands as published.
#   'd'  suppressed (NA)     '-'  none reported (0)
#   '*'  use-with-caution    'blank' empty cell
# Parenthesized values are negatives in the money tables. The PERCENT tables
# (coefficients of variation) instead write their footnote references in
# parentheses -- "(4)" where a CV is not defined, 161 such cells in the TY2010
# Table 1 CV file -- and write the rare genuinely negative CV with a minus
# sign, so those callers pass paren_negative = FALSE and get a footnote flag
# instead of a spurious -4.
clean_value = function(x, paren_negative = TRUE) {
  if (grepl('^\\[[0-9]+\\]$', trimws(x))) {   # footnote-only cell, e.g. "[2]"
    return(list(value = NA_real_, flag = trimws(x)))
  }
  if (!paren_negative && grepl('^\\([0-9]+\\)$', trimws(x))) {
    return(list(value = NA_real_, flag = trimws(x)))
  }
  raw = trimws(gsub('\\[[0-9]+\\]', '', x))
  raw = gsub(',', '', raw)
  if (raw == '')                 return(list(value = NA_real_, flag = 'blank'))
  if (tolower(raw) == 'd')       return(list(value = NA_real_, flag = 'd'))
  if (grepl('^-+$', raw))        return(list(value = 0,        flag = '-'))
  flag = NA_character_
  if (startsWith(raw, '*')) {
    flag = '*'
    raw  = trimws(sub('^\\*+', '', raw))
    if (raw == '') return(list(value = NA_real_, flag = '*'))
  }
  neg = grepl('^\\(.*\\)$', raw)
  if (neg) raw = sub('^\\((.*)\\)$', '\\1', raw)
  val = suppressWarnings(as.numeric(raw))
  if (is.na(val)) stop('unparseable value: "', x, '"')
  list(value = if (neg) -val else val, flag = flag)
}

# Blank every cell a merged range covers except the range's own anchor. Those
# cells are invisible in the published sheet but may still hold text, and the
# modern Table 5.1 files are full of it: each column header is merged down
# rows 5-11 over the PREVIOUS layout's wrapped label, so column 104 carries
# both "Farm product raw material" (what the table shows) and "Sporting
# goods, hobby, book, and music stores" (what it showed in an earlier year).
# Stacking without this glues the two together.
blank_covered = function(m, merges) {
  for (r in seq_len(nrow(merges))) {
    rows = merges$first_row[r]:merges$last_row[r]
    cols = merges$first_col[r]:merges$last_col[r]
    rows = rows[rows <= nrow(m)]
    cols = cols[cols <= ncol(m)]
    if (length(rows) == 0 || length(cols) == 0) next
    anchor = m[rows[1], cols[1]]
    m[rows, cols] = ''
    m[rows[1], cols[1]] = anchor
  }
  m
}

# Stacked header text for each data column: everything in the header rows
# in that column, whitespace-collapsed (headers wrap across rows and lines).
# hdr_rows is the vector of row indices forming the header block (for a
# stacked lower panel this starts after the previous panel's data, not at 1).
# Title/units lines are excluded: they occupy a single (often merged) cell
# with long text, sometimes sitting IN a data column (2004-06 vintages), so
# drop header rows whose only non-empty data-column cell is a long sentence.
stack_headers = function(m, hdr_rows, cols, merges = NULL) {
  if (!is.null(merges) && nrow(merges) > 0) {
    hdr = merges[merges$first_row %in% hdr_rows, , drop = FALSE]
    if (nrow(hdr) > 0) m = blank_covered(m, hdr)
  }
  keep = vapply(hdr_rows, function(i) {
    filled = which(m[i, cols] != '')
    !(length(filled) == 1 && nchar(m[i, cols[filled]]) > 40)
  }, logical(1))
  vapply(cols, function(j) {
    txt = paste(m[hdr_rows[keep], j], collapse = ' ')
    trimws(gsub('\\s+', ' ', txt))
  }, character(1))
}

#-------------------------------------------------
# Merged header cells -> column hierarchy groups
#-------------------------------------------------

# Merged-cell ranges of the first sheet as data.frame(first_row, last_row,
# first_col, last_col), 1-based inclusive. The industry spanners in the
# column-industry tables (old 6/7/12/13, modern 5.x, ...) are merged cells;
# positional inference cannot recover their extent (single-column sectors
# like Utilities sit BETWEEN multi-column spanners), so the real ranges are
# read from the file: xlsx from the sheet XML, .xls via python/xlrd. The
# 1994-2003 .xls vintages carry no merge records at all -> zero rows, and
# column groups are simply unavailable for them (sector-total columns are
# still identifiable there because the spanner text sits in the sector's
# first column and lands in that column's stacked label).
sheet_merges = function(path, helper_dir) {
  empty = data.frame(first_row = integer(), last_row = integer(),
                     first_col = integer(), last_col = integer())
  if (grepl('\\.xlsx$', path, ignore.case = TRUE)) {
    # extract-to-tempfile: readLines on an unz() connection silently stops
    # at the XML declaration (the sheet XML is one giant newline-less line)
    xml = tryCatch({
      f = utils::unzip(path, files = 'xl/worksheets/sheet1.xml',
                       exdir = tempdir(), junkpaths = TRUE, overwrite = TRUE)
      readChar(f, file.size(f), useBytes = TRUE)
    }, error = function(e) '', warning = function(w) '')
    refs = regmatches(xml, gregexpr('<mergeCell ref="[A-Z0-9]+:[A-Z0-9]+"',
                                    xml))[[1]]
    if (length(refs) == 0) return(empty)
    a1_col = function(s) Reduce(function(a, ch) a * 26L + (ch - 64L),
                                utf8ToInt(gsub('[0-9]', '', s)), 0L)
    a1_row = function(s) as.integer(gsub('[A-Z]', '', s))
    corners = sub('.*ref="([A-Z0-9:]+)"', '\\1', refs)
    from = sub(':.*', '', corners)
    to   = sub('.*:', '', corners)
    return(data.frame(
      first_row = vapply(from, a1_row, integer(1), USE.NAMES = FALSE),
      last_row  = vapply(to,   a1_row, integer(1), USE.NAMES = FALSE),
      first_col = vapply(from, a1_col, integer(1), USE.NAMES = FALSE),
      last_col  = vapply(to,   a1_col, integer(1), USE.NAMES = FALSE)))
  }
  if (Sys.which('python3') == '') return(empty)
  helper = file.path(helper_dir, 'read_xls_merges.py')
  lines = suppressWarnings(
    system2('python3', c(shQuote(helper), shQuote(path)),
            stdout = TRUE, stderr = FALSE))
  status = attr(lines, 'status')
  if ((!is.null(status) && status != 0) || length(lines) == 0) return(empty)
  d = utils::read.csv(text = paste(lines, collapse = '\n'), header = FALSE,
                      col.names = c('first_row', 'last_row',
                                    'first_col', 'last_col'))
  d
}

# Hierarchy path for each data column: the anchor text of every merged
# header cell that spans >= 2 data columns and covers the column, joined
# top-to-bottom with ' > ' ("Manufacturing", "Wholesale and retail trade >
# Retail trade"). '' where no spanner covers the column (single-column
# sectors, the stub, files without merge records). Excluded as
# title/units lines rather than spanners: anchors > 60 chars, merges
# split into chunks, and merges covering > 80% of the data columns (a
# group that spans the whole table describes the table, not a split).
col_groups = function(m, hdr_rows, cols, merges) {
  if (nrow(merges) == 0) return(rep('', length(cols)))
  # anchors can sit outside the matrix readxl returns (trailing empty area)
  mg = merges[merges$first_row %in% hdr_rows & merges$first_col <= ncol(m), ,
              drop = FALSE]
  if (nrow(mg) == 0) return(rep('', length(cols)))
  mg$text = normalize_label(m[cbind(mg$first_row, mg$first_col)])
  mg$text = sub('\\s*-+\\s*continued$', '', mg$text, ignore.case = TRUE)
  spans = vapply(seq_len(nrow(mg)), function(r)
    sum(cols >= mg$first_col[r] & cols <= mg$last_col[r]), integer(1))
  mg = mg[mg$text != '' & nchar(mg$text) <= 60 &
            spans >= 2 & spans <= 0.8 * length(cols), , drop = FALSE]
  mg = mg[order(mg$first_row, mg$first_col), , drop = FALSE]
  vapply(cols, function(j) {
    paste(mg$text[mg$first_col <= j & mg$last_col >= j], collapse = ' > ')
  }, character(1))
}

#----------------------------------------
# Item labels: drift harmonization
#----------------------------------------

# Variant -> canonical item label across eras, canonical being the modern
# label where one exists. Shared by every panel whose ROWS (or, in the
# industry-column tables, whose stub) are the balance-sheet / income-statement
# items: the same stub is published in Tables 2, 3, 5, 6 and their modern
# successors, so one table serves all of them. Curated from the coverage
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
  'paid-in or capital surplus'      = 'additional paid-in capital',

  'mortgages, notes, and bonds payable in less than one year' =
    'mortgages, notes, bonds payable in less than 1 year',
  'mortgages,notes,and bonds payable in less than one year' =
    'mortgages, notes, bonds payable in less than 1 year',
  'mortgages, notes, and bonds under one year' =
    'mortgages, notes, bonds payable in less than 1 year',
  'mortgages, notes, bonds payable less than 1 yr' =
    'mortgages, notes, bonds payable in less than 1 year',
  # TY2013 Table 6 drops the "less" from the published stub
  'mortgages, notes, and bonds payable in than one year' =
    'mortgages, notes, bonds payable in less than 1 year',
  'mortgages, notes, and bonds payable in one year or more' =
    'mortgages, notes, bonds payable in 1 year or more',
  'mortgages,notes,and bonds payable in one year or more' =
    'mortgages, notes, bonds payable in 1 year or more',
  'mortgages, notes, bonds, one year or more' =
    'mortgages, notes, bonds payable in 1 year or more',
  'mortgages, notes, bonds payable 1 yr. or more' =
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
  'pension,profit-sharing,stock bonus, annuity plans' =
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
  # extract_sheet strips the colon when it turns a wrapped stub's first line
  # into a section, so the glued-back label arrives without one
  'interest on government obligations state and local' =
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

#-------------------------------------
# The Form 1120S stub
#-------------------------------------

# Renames confined to the 1120S stub, applied after the shared ITEM_ALIASES.
# They stay separate rather than joining the table above because two of them
# collide with the corporate stub: "dividends" is the modern 5.x receipts
# line, and "depreciation" a deduction in every corporate table.
#   * 2004-2013 write the capital-gain and rental lines longhand, the modern
#     files shorten them and swap the rental word order;
#   * TY2007's files substitute "0" for the hyphen throughout the stub
#     ("net short0term", "pension, profit0sharing");
#   * TY2006-2012 misspells "business" in the net income line.
S_ITEM_ALIASES = c(
  'net short-term capital gain (less loss)' = 'net short-term capital gain (loss)',
  'net long-term capital gain (less loss)'  = 'net long-term capital gain (loss)',
  'net short0term capital gain (less loss)' = 'net short-term capital gain (loss)',
  'net long0term capital gain (less loss)'  = 'net long-term capital gain (loss)',
  'pension, profit0sharing, stock, annuity' = 'pension, profit-sharing, etc., plans',
  'royalty income'                          = 'gross royalties',
  'dividends'                               = 'dividend income',
  'rental real estate net income (less deficit)' =
    'real estate rental net income (less deficit)',
  'depreciation from form 4562'             = 'depreciation',
  'net gain (loss) from sales of business property' =
    'net gain (less loss) sales of business property',
  'net income from a trade or buisness'     = 'net income from a trade or business'
)

apply_s_alias = function(item) {
  hit = item %in% names(S_ITEM_ALIASES)
  item[hit] = unname(S_ITEM_ALIASES[item[hit]])
  item
}

# The 1120S stub prints a net figure and then its two halves on rows labelled
# with nothing but the halves' generic names, and the SAME two words recur
# under several parents -- old 1120S Table 1 prints "Net income" and "Deficit"
# four times over, under the trade-or-business, real-estate-rental,
# other-rental and total net income figures. A split row takes its parent's
# name, the nearest row above it that is not itself a split.
#
# This is 1120S-only. In the corporate stub a bare "Net income" row is an item
# in its own right -- Tables 5.2 and 5.4 cover returns WITH net income, so they
# publish it as a line rather than as half of a net figure.
SPLIT_LABELS = c('net income', 'deficit', 'income', 'gain', 'loss')

qualify_splits = function(item) {
  split = item %in% SPLIT_LABELS
  if (!any(split)) return(item)
  parent = item
  parent[split] = NA_character_
  for (i in which(split)) if (i > 1) parent[i] = parent[i - 1]
  if (anyNA(parent[split])) stop('split item row with no parent above it')
  item[split] = paste0(parent[split], ': ', item[split])
  item
}

#-------------------------------------
# Size-class column normalization
#-------------------------------------

# Turn a stacked size-class column header into canonical pieces. Headers
# arrive like "Size of total assets Zero assets", "1.0 under $100,000",
# "$2,500,000,000 or more", "Total returns of active corporations", plain
# "Total", or with merged-cell echoes ("$1 under $500 under 500") -- ranges
# are taken from the FIRST match. Returns list(col_type, lo, hi); bound
# scaling and canonical labeling are the caller's job (some vintages state
# class bounds in thousands).
parse_class_header = function(hdr, span_phrases) {
  h = tolower(hdr)
  for (p in span_phrases) h = sub(p, '', h, fixed = TRUE)
  h = gsub('\\[[0-9]+\\]', '', h)
  h = trimws(gsub('\\s+', ' ', h))
  # wide vintages repeat the spanner as "... -- continued" over the second
  # column panel; drop the leftover once the span phrase itself is stripped
  h = trimws(sub('^[-–— ]*continued[ .:]*', '', h))
  num = function(s) as.numeric(gsub('[$,]|\\.0$', '', s))
  if (grepl('zero assets', h))
    return(list(col_type = 'zero_assets', lo = NA_real_, hi = NA_real_))
  if (h %in% c('total', 'total assets', 'total receipts') ||
      grepl('total returns (of active|with net income)', h) ||
      grepl('^total,? all', h))
    return(list(col_type = 'total', lo = NA_real_, hi = NA_real_))
  mm = regmatches(h, regexec('\\$?([0-9][0-9,.]*) under \\$?([0-9][0-9,.]*)', h))[[1]]
  if (length(mm) == 3) {
    return(list(col_type = 'size_class', lo = num(mm[2]), hi = num(mm[3])))
  }
  mm = regmatches(h, regexec('^under \\$?([0-9][0-9,.]*)', h))[[1]]
  if (length(mm) == 2) {
    return(list(col_type = 'size_class', lo = 1, hi = num(mm[2])))
  }
  mm = regmatches(h, regexec('\\$?([0-9][0-9,.]*) or more', h))[[1]]
  if (length(mm) == 2) {
    return(list(col_type = 'size_class', lo = num(mm[2]), hi = NA_real_))
  }
  NULL   # not a recognizable class column -- caller decides what to do
}

# The same job for a column classified by a COUNT rather than a money amount:
# 1120S Table 6 / modern Table 9 break returns out by number of shareholders,
# heading the columns "Total", "1", "2", "3", "4-10", "11-20", "21-30" and
# "31 or more" (TY2013 and earlier: "31 or greater"). Ranges are inclusive on
# both ends, so a single number is the class lo == hi, and the open top class
# has hi = NA -- the same shape parse_class_header returns.
parse_count_header = function(hdr, span_phrases) {
  h = tolower(hdr)
  for (p in span_phrases) h = sub(p, '', h, fixed = TRUE)
  h = gsub('\\[[0-9]+\\]', '', h)
  h = gsub('[–—]', '-', h)          # en/em dash -> hyphen
  h = trimws(gsub('\\s+', ' ', h))
  if (h %in% c('total', 'total returns')) {
    return(list(col_type = 'total', lo = NA_real_, hi = NA_real_))
  }
  mm = regmatches(h, regexec('^([0-9]+)\\s*-\\s*([0-9]+)$', h))[[1]]
  if (length(mm) == 3) {
    return(list(col_type = 'count_class', lo = as.numeric(mm[2]),
                hi = as.numeric(mm[3])))
  }
  mm = regmatches(h, regexec('^([0-9]+) or (more|greater)$', h))[[1]]
  if (length(mm) == 3) {
    return(list(col_type = 'count_class', lo = as.numeric(mm[2]), hi = NA_real_))
  }
  if (grepl('^[0-9]+$', h)) {
    return(list(col_type = 'count_class', lo = as.numeric(h), hi = as.numeric(h)))
  }
  NULL
}

#-------------------------------------------------
# Whole-sheet extraction (the composite entry point)
#-------------------------------------------------

# Stub anchor for vintages with no column-number row
FIRST_ITEM_REGEX = paste0('^(number of returns|total returns of active|',
                          'all industries|all sectors)')

#--------------------------
# Generic sheet extraction
#--------------------------

# Parse one published sheet into long rows keyed on (row_label, col_label).
# Returns data.frame or NULL rows for note lines. Section-header stub rows
# (label present, no data at all) become the `section` of following rows.
# Sheets stacking a continuation block below the first yield one combined
# frame either way (see find_numrows): a 'cols' block extends col_seq (1996
# Table 1's columns 21-40), a 'rows' block restarts it because the sheet is
# paginated and the block carries further industries (the 2001 Table 1 CV
# file's four pages). Two hierarchy columns ride along:
#   row_indent  leading spaces of the stub cell as published -- the industry
#               hierarchy in the Table 1 family (indent WIDTHS vary by file
#               and even by block, so classification is the caller's job)
#   col_group   ' > '-joined industry spanners covering the column, from
#               merged header cells; '' before 2003 (no merge records)
# paren_negative = FALSE for percent (CV) sheets -- see clean_value.
extract_sheet = function(path, helper_dir, paren_negative = TRUE) {
  raw = read_sheet_matrix(path, helper_dir, trim = 'right')
  m   = trimws(raw)
  locs = find_numrows(m)
  if (length(locs) == 0) {
    fb = find_data_block(m, FIRST_ITEM_REGEX)
    # 'row' is already the line above the data
    panels = list(list(row = fb$row, cols = fb$cols, kind = 'cols',
                       hdr_rows = seq_len(fb$row), data_end = nrow(m)))
  } else {
    panels = lapply(seq_along(locs), function(k) {
      loc = locs[[k]]
      hdr_start = if (k == 1) 1 else {
        # a lower panel's header block: scan up from its column-number row
        # to just past the previous panel's last data-carrying row
        i = loc$row - 1
        while (i > locs[[k - 1]]$row &&
               sum(looks_data_cell(m[i, loc$cols])) < 2) i = i - 1
        i + 1
      }
      # exclude the column-number row itself
      list(row = loc$row, cols = loc$cols, kind = loc$kind,
           hdr_rows = hdr_start:(loc$row - 1))
    })
    for (k in seq_along(panels)) {
      panels[[k]]$data_end = if (k < length(panels)) {
        panels[[k + 1]]$hdr_rows[1] - 1
      } else nrow(m)
    }
  }
  # col_seq offset per block: a paginated ('rows') block restarts the columns
  offsets = integer(length(panels))
  off = 0L
  for (k in seq_along(panels)) {
    if (panels[[k]]$kind == 'rows') off = 0L
    offsets[k] = off
    off = off + length(panels[[k]]$cols)
  }
  merges = sheet_merges(path, helper_dir)

  # require the colon (or a bare "Notes") so items like "Notes and accounts
  # receivable" don't get swallowed as footnote lines
  note_regex = '^(notes?\\s*:|notes?$|source\\s*:|footnotes?\\b|\\*|d -|\\[)'
  out = list()
  for (k in seq_along(panels)) {
    p = panels[[k]]
    col_off = offsets[k]
    headers = stack_headers(m, p$hdr_rows, p$cols, merges)
    groups  = col_groups(m, p$hdr_rows, p$cols, merges)
    label_cols = seq_len(min(p$cols) - 1)
    min_cells  = max(2, ceiling(0.1 * length(p$cols)))
    section = NA_character_
    for (i in (p$row + 1):p$data_end) {
      lab_cells = m[i, label_cols]
      # take the label cell CLOSEST to the data: 2004-06 vintages carry a
      # stray print page number in the first column
      lab_idx = rev(which(lab_cells != ''))[1]
      label_raw = if (is.na(lab_idx)) '' else lab_cells[lab_idx]
      if (grepl('^[0-9.]+$', label_raw)) label_raw = ''   # page-number cell
      label = normalize_label(label_raw)
      cells = m[i, p$cols]
      n_filled = sum(cells != '')
      # footnote guard runs on the RAW label: normalize_label strips leading
      # "[1]" markers, which would let note lines masquerade as row labels
      if (grepl(note_regex, tolower(trimws(label_raw)))) next
      if (label == '' && n_filled == 0) next
      if (label != '' && n_filled == 0) {          # section header stub
        section = sub(':$', '', label)
        next
      }
      if (label == '' || n_filled < min_cells) {
        next                                        # stray / spill-over line
      }
      stub = raw[i, label_cols[lab_idx]]
      indent = nchar(stub) - nchar(sub('^ +', '', stub))
      cleaned = lapply(cells, clean_value, paren_negative = paren_negative)
      out[[length(out) + 1]] = data.frame(
        row_seq    = i,
        section    = section,
        row_label  = label,
        row_indent = indent,
        col_seq    = col_off + seq_along(p$cols),
        col_label  = normalize_label(headers),
        col_group  = groups,
        value      = unname(vapply(cleaned, function(v) v$value, numeric(1))),
        flag       = unname(vapply(cleaned, function(v) v$flag,  character(1))),
        row.names = NULL, stringsAsFactors = FALSE
      )
    }
  }
  df = do.call(rbind, out)
  if (is.null(df) || length(unique(df$row_label)) < 5) {
    stop(path, ': parsed only ', length(unique(df$row_label)), ' data rows')
  }
  df
}
