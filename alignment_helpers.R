#------------------------------------------------------------------------------
# alignment_helpers.R
#
# Shared parsing machinery for the Corporation Complete Report aligners
# (align_table4.R, align_tables.R). Everything here is table-agnostic:
# reading a sheet as a text matrix (with the BIFF4 python fallback), locating
# the column-number row, cleaning SOI cell values, and normalizing labels.
#
# Sourced with `HELPER_DIR` pointing at this repo (for read_biff4.py).
#------------------------------------------------------------------------------

suppressMessages(library(readxl))

#-----------------------
# Read a sheet as text
#-----------------------

read_sheet_matrix = function(path, helper_dir) {
  m = tryCatch({
    d = suppressWarnings(suppressMessages(
      read_excel(path, col_names = FALSE, col_types = 'text',
                 .name_repair = 'minimal')))
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
  trimws(m)
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
      return(list(row = i, cols = idx))
    }
  }
  NULL
}

# Fallback for vintages without a column-number row: anchor the first data
# row on its stub label, then keep the columns that actually carry data.
find_data_block = function(m, first_item_regex) {
  labels = tolower(m[, 1])
  first = which(grepl(first_item_regex, labels))[1]
  if (is.na(first)) stop('first data row (', first_item_regex, ') not found')
  looks_data = function(x) {
    x = gsub('\\[[0-9]+\\]|[,*]', '', x)
    x != '' & (grepl('^\\(?-?[0-9.]+\\)?$', x) | tolower(x) == 'd' |
                 grepl('^-+$', x))
  }
  body = m[first:nrow(m), , drop = FALSE]
  n_data = apply(body, 2, function(col) sum(looks_data(col)))
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

# Stacked header text for each data column: everything above the data block
# in that column, whitespace-collapsed (headers wrap across rows and lines).
# Title/units lines are excluded: they occupy a single (often merged) cell
# with long text, sometimes sitting IN a data column (2004-06 vintages), so
# drop header rows whose only non-empty data-column cell is a long sentence.
stack_headers = function(m, hdr_end, cols) {
  keep = vapply(seq_len(hdr_end), function(i) {
    filled = which(m[i, cols] != '')
    !(length(filled) == 1 && nchar(m[i, cols[filled]]) > 40)
  }, logical(1))
  vapply(cols, function(j) {
    txt = paste(m[which(keep), j], collapse = ' ')
    trimws(gsub('\\s+', ' ', txt))
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
