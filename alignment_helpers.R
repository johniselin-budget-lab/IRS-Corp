#------------------------------------------------------------------------------
# alignment_helpers.R
#
# Shared parsing machinery for the Corporation Complete Report aligners
# (align_table4.R, align_tables.R). Everything here is table-agnostic:
# reading a sheet as a text matrix (with the BIFF4 python fallback), locating
# the column-number row(s) (including stacked lower panels), cleaning SOI
# cell values, normalizing labels, and recovering the industry-spanner
# hierarchy from merged header cells.
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
read_sheet_matrix = function(path, helper_dir, trim = 'both') {
  m = tryCatch({
    d = suppressWarnings(suppressMessages(
      read_excel(path, col_names = FALSE, col_types = 'text',
                 .name_repair = 'minimal', trim_ws = FALSE)))
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

# SOI marks data columns with a row of consecutive numbers under the header
# block: "1 2 3 ...", "(1) (2) ...", and in continuation tables the sequence
# starts above 1 (Table 1 part 2 numbers its columns 16, 17, ...). The
# sequence occasionally skips a number (2014 Table 5.1 jumps 25 -> 27), so
# accept strictly-increasing integer runs that are >= 90% consecutive.
# Returns list(row, cols) or NULL if the vintage has no such row (some
# early-2000s files) -- callers fall back to find_data_block().
find_numrow = function(m, max_scan = 30) {
  for (i in seq_len(min(max_scan, nrow(m)))) {
    v = suppressWarnings(as.numeric(gsub('^\\((.*)\\)$', '\\1', m[i, ])))
    idx = which(!is.na(v))
    if (length(idx) < 5) next
    run = v[idx]
    # "(1) (2) ..." stored as accounting-format numbers arrives as -1 -2 ...
    if (all(run < 0)) run = -run
    if (all(run == round(run)) && run[1] >= 1 && run[1] < 100 &&
        max(run) < 1000 && all(diff(run) >= 1) &&
        mean(diff(run) == 1) >= 0.9) {
      return(list(row = i, cols = idx, vals = run))
    }
  }
  NULL
}

# All column-number rows in a sheet. Some old wide tables stack a SECOND
# panel below the first with the same stub and continued column numbers
# (1996 Table 1: rows 1-308 hold columns 1-20, rows 309+ repeat the title
# and stub with columns numbered 21-40). The first panel is located exactly
# as find_numrow() does; a continuation row must pick up numbering at
# prev_max + 1 and contain NOTHING but the number run (data rows never do).
# Returns a list of list(row, cols, vals); empty list if no numrow at all.
find_numrows = function(m) {
  first = find_numrow(m)
  if (is.null(first)) return(list())
  panels = list(first)
  i = first$row + 1
  while (i <= nrow(m)) {
    v = suppressWarnings(as.numeric(gsub('^\\((.*)\\)$', '\\1', m[i, ])))
    idx = unname(which(!is.na(v)))
    if (length(idx) >= 5 && identical(unname(which(m[i, ] != '')), idx)) {
      run = v[idx]
      if (all(run < 0)) run = -run
      prev = panels[[length(panels)]]$vals
      if (all(run == round(run)) && run[1] == max(prev) + 1 &&
          max(run) < 1000 && all(diff(run) >= 1) &&
          mean(diff(run) == 1) >= 0.9) {
        panels[[length(panels) + 1]] = list(row = i, cols = idx, vals = run)
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
  x = gsub('\\[[0-9]+\\]', '', x)   # footnote refs
  x = gsub('[.*]+$', '', trimws(x)) # trailing dot leaders / asterisks
  trimws(gsub('\\s+', ' ', x))
}

# One SOI cell -> list(value, flag). Money in thousands as published.
#   'd'  suppressed (NA)     '-'  none reported (0)
#   '*'  use-with-caution    'blank' empty cell
# Parenthesized values are negatives.
clean_value = function(x) {
  if (grepl('^\\[[0-9]+\\]$', trimws(x))) {   # footnote-only cell, e.g. "[2]"
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

# Stacked header text for each data column: everything in the header rows
# in that column, whitespace-collapsed (headers wrap across rows and lines).
# hdr_rows is the vector of row indices forming the header block (for a
# stacked lower panel this starts after the previous panel's data, not at 1).
# Title/units lines are excluded: they occupy a single (often merged) cell
# with long text, sometimes sitting IN a data column (2004-06 vintages), so
# drop header rows whose only non-empty data-column cell is a long sentence.
stack_headers = function(m, hdr_rows, cols) {
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
