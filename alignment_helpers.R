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
# Sheets that stack a continuation panel below the first (1996 Table 1:
# columns 21-40 under a repeated title and stub) yield one combined frame,
# col_seq continuing across panels. Two hierarchy columns ride along:
#   row_indent  leading spaces of the stub cell as published -- the industry
#               hierarchy in the Table 1 family (indent WIDTHS vary by file
#               and even by block, so classification is the caller's job)
#   col_group   ' > '-joined industry spanners covering the column, from
#               merged header cells; '' before 2003 (no merge records)
extract_sheet = function(path, helper_dir) {
  raw = read_sheet_matrix(path, helper_dir, trim = 'right')
  m   = trimws(raw)
  locs = find_numrows(m)
  if (length(locs) == 0) {
    fb = find_data_block(m, FIRST_ITEM_REGEX)
    # 'row' is already the line above the data
    panels = list(list(row = fb$row, cols = fb$cols,
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
      list(row = loc$row, cols = loc$cols, hdr_rows = hdr_start:(loc$row - 1))
    })
    for (k in seq_along(panels)) {
      panels[[k]]$data_end = if (k < length(panels)) {
        panels[[k + 1]]$hdr_rows[1] - 1
      } else nrow(m)
    }
  }
  merges = sheet_merges(path, helper_dir)

  # require the colon (or a bare "Notes") so items like "Notes and accounts
  # receivable" don't get swallowed as footnote lines
  note_regex = '^(notes?\\s*:|notes?$|source\\s*:|footnotes?\\b|\\*|d -|\\[)'
  out = list()
  col_off = 0
  for (p in panels) {
    headers = stack_headers(m, p$hdr_rows, p$cols)
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
      cleaned = lapply(cells, clean_value)
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
    col_off = col_off + length(p$cols)
  }
  df = do.call(rbind, out)
  if (is.null(df) || length(unique(df$row_label)) < 5) {
    stop(path, ': parsed only ', length(unique(df$row_label)), ' data rows')
  }
  df
}
