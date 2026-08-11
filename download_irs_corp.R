#!/usr/bin/env Rscript
#------------------------------------------------------------------------------
# download_irs_corp.R
#
# Downloads an organized copy of the IRS SOI Corporation Complete Report
# (Publication 16) basic tables:
#   2014+ :  https://www.irs.gov/statistics/soi-tax-stats-corporation-income-
#            tax-returns-complete-report-publication-16
#   1994-2013: https://www.irs.gov/statistics/soi-tax-stats-corporation-
#            complete-report-1994-to-2013 (one zip archive per tax year)
#
# The DESTINATION is configurable: by default data lands in this repo's own
# (gitignored) data/ folder; pass --dest to download to a separate location
# instead (e.g. the shared cluster store). Layout under the destination:
#
#   modern/table_{id}/   table_{id}_{year}.xlsx   2014+ basic tables, one dir
#                                                 per table (id = SOI table
#                                                 number, e.g. table_4,
#                                                 table_2_1a, table_1_cv)
#   archive/{year}/      as-published contents of the {yy}coalcr.zip /
#                        {yy}coalccr.zip archive for 1994-2013: .xls tables
#                        (numbered 1-27, a DIFFERENT scheme from 2014+ -- see
#                        docs/table_crosswalk_2014.pdf), documentation PDFs,
#                        and for the mid-1990s legacy .WK1/.FMT companions
#   docs/                table_crosswalk_2014.pdf  old->new table-number map
#        pub16/          p16--{rev}.pdf   full Pub 16 PDFs by REVISION year
#                                         (each covers a tax year ~3 years
#                                         earlier; kept under as-published
#                                         names)
#   manifest.csv         path, source url, year, bytes, md5, retrieval date
#
# Source-naming quirks encoded below (verified against irs.gov 2026-08-11):
#   - Modern basic tables: {yy}co{code}ccr.xlsx, codes in MODERN_TABLES.
#     Table 14 begins TY2015 (2014 404s and is skipped). Table 13 changes
#     definition in 2017 (13.1, non-S/REIT/RIC only, through 2016; all
#     active corporations from 2017) but keeps the same filename.
#   - Archive zips: {yy}coalcr.zip for 1994-2009, {yy}coalccr.zip for
#     2010-2013. Table filenames inside change scheme several times
#     (94CO22AC.XLS / CRTAB22.XLS / CRTB22.XLS / TABL22.XLS / {yy}co22nr.xls
#     / {yy}co22ccr.xls for what is the same table); files are stored
#     as-published, one folder per year, paths flattened.
#   - The complete-report PDF and its section/endnote PDFs ship inside the
#     zips themselves (some under stray nested folders -- flattened here),
#     so no separate PDF pull is needed for 1994-2013.
#
# Usage:
#   Rscript download_irs_corp.R                          # -> ./data, 1994-2022
#   Rscript download_irs_corp.R 2014 2023                # custom year range
#   Rscript download_irs_corp.R --dest /path/to/store    # separate location
#   Rscript download_irs_corp.R --dest /path/to/store 2014 2023
#
# Budget Lab internal users: pass the lab's shared raw_data store (documented
# internally) via --dest.
#
# Idempotent: existing target files are skipped, and an archive/{year} folder
# that already has files is not re-fetched (delete it to re-extract). Missing
# years/files (HTTP 404) are skipped with a message. manifest.csv is rewritten
# from what is on disk each run (prior retrieval dates preserved).
# Base R only; extraction via the system unzip binary.
#------------------------------------------------------------------------------

#-----------------
# Parse arguments
#-----------------

args = commandArgs(trailingOnly = TRUE)

script_dir = dirname(sub('--file=', '', grep('--file=', commandArgs(), value = TRUE)[1]))
if (is.na(script_dir) || script_dir == '') script_dir = '.'

dest = file.path(script_dir, 'data')
if (length(args) > 0 && args[1] == '--dest') {
  if (length(args) < 2) stop('--dest requires a path')
  dest = args[2]
  args = args[-(1:2)]
}
years = if (length(args) >= 2) as.integer(args[1]):as.integer(args[2]) else 1994:2022

dir.create(dest, recursive = TRUE, showWarnings = FALSE)
message('Destination: ', normalizePath(dest))

BASE       = 'https://www.irs.gov/pub/irs-soi'
BASE_PRIOR = 'https://www.irs.gov/pub/irs-prior'

#---------------------------
# Source file specifications
#---------------------------

# Modern (2014+) basic tables: SOI filename code -> folder/file id.
# The id is the table number as printed in the publication (Table 1,
# Table 2.1A, ...), so modern/table_4/ holds Table 4 for every year.
# (table numbers zero-padded so folder listings sort in publication order)
MODERN_TABLES = c(
  '01'   = 'table_01',    # Table 1 part 1: all active corps, selected items
  '01cv' = 'table_01_cv', # Table 1 part 2: coefficients of variation
  '21'   = 'table_02_1',  # Table 2.1: balance sheet/income statement
  '21a'  = 'table_02_1a', # Table 2.1A: pct distribution of total assets
  '22'   = 'table_02_2',  # Table 2.2: returns with net income
  '23'   = 'table_02_3',  # Table 2.3: non-S/REIT/RIC
  '24'   = 'table_02_4',  # Table 2.4: Form 1120S
  '24a'  = 'table_02_4a', # Table 2.4A: 1120S pct distribution of assets
  '31'   = 'table_03_1',  # Table 3.1: by size of total assets
  '32'   = 'table_03_2',  # Table 3.2: 1120S by size of total assets
  '33'   = 'table_03_3',  # Table 3.3: non-S/REIT/RIC by size of assets
  '04'   = 'table_04',    # Table 4: by size of total income tax after credits
  '51'   = 'table_05_1',  # Table 5.1: by size of business receipts
  '52'   = 'table_05_2',  # Table 5.2: net-income returns by receipts
  '53'   = 'table_05_3',  # Table 5.3: non-S/REIT/RIC by receipts
  '54'   = 'table_05_4',  # Table 5.4: non-S/REIT/RIC net-income by receipts
  '61'   = 'table_06_1',  # Table 6.1: 1120S balance sheet/income statement
  '62'   = 'table_06_2',  # Table 6.2: 1120S net-income returns
  '07'   = 'table_07',    # Table 7: 1120S portfolio/rental/total net income
  '08'   = 'table_08',    # Table 8: 1120S Form 8825 rental real estate
  '09'   = 'table_09',    # Table 9: 1120S receipts/deductions detail
  '10'   = 'table_10',    # Table 10: Form 1120-F
  '11'   = 'table_11',    # Table 11: dividends/special deductions
  '12'   = 'table_12',    # Table 12: Form 1125-A cost of goods sold
  '13'   = 'table_13',    # Table 13: Form 4562 depreciation (13.1 pre-2017)
  '14'   = 'table_14'     # Table 14: Form 6765 research credit (2015+)
)

archive_zip = function(yy, year) {
  if (year >= 2010) sprintf('%scoalccr.zip', yy) else sprintf('%scoalcr.zip', yy)
}

modern_targets = function(year) {
  yy = sprintf('%02d', year %% 100)
  tg = lapply(names(MODERN_TABLES), function(code) {
    id = MODERN_TABLES[[code]]
    list(url = file.path(BASE, sprintf('%sco%sccr.xlsx', yy, code)),
         to  = sprintf('modern/%s/%s_%d.xlsx', id, id, year))
  })
  if (year == 2014) {
    tg = c(tg, list(list(url = file.path(BASE, '14cotablecrosswalkccr.pdf'),
                         to  = 'docs/table_crosswalk_2014.pdf')))
  }
  tg
}

#----------
# Download
#----------

fetch_file = function(url, to) {
  if (file.exists(to)) {
    message('  exists, skipping: ', to)
    return(invisible('exists'))
  }
  dir.create(dirname(to), recursive = TRUE, showWarnings = FALSE)
  ok = tryCatch(
    utils::download.file(url, to, mode = 'wb', quiet = TRUE) == 0,
    error   = function(e) FALSE,
    warning = function(w) FALSE
  )
  if (!ok || !file.exists(to) || file.size(to) == 0) {
    unlink(to)
    message('  not available (skipped): ', url)
    return(invisible('missing'))
  }
  message('  downloaded: ', to, '  (', format(file.size(to), big.mark = ','), ' bytes)')
  invisible('downloaded')
}

# Download the year's zip and extract it flat into archive/{year}/.
# Returns 'exists' / 'downloaded' / 'missing'.
fetch_archive_year = function(year) {
  yy      = sprintf('%02d', year %% 100)
  out_dir = sprintf('archive/%d', year)
  if (dir.exists(out_dir) && length(list.files(out_dir)) > 0) {
    message('  exists, skipping: ', out_dir, '/')
    return(invisible('exists'))
  }
  url = file.path(BASE, archive_zip(yy, year))
  tmp = tempfile(fileext = '.zip')
  on.exit(unlink(tmp))
  ok = tryCatch(
    utils::download.file(url, tmp, mode = 'wb', quiet = TRUE) == 0,
    error   = function(e) FALSE,
    warning = function(w) FALSE
  )
  if (!ok || !file.exists(tmp) || file.size(tmp) == 0) {
    message('  not available (skipped): ', url)
    return(invisible('missing'))
  }
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  # -j flattens the stray nested folders in some zips (e.g. 2012/2013)
  status = system2('unzip', c('-j', '-o', '-qq', shQuote(tmp), '-d', shQuote(out_dir)))
  if (status != 0 || length(list.files(out_dir)) == 0) {
    unlink(out_dir, recursive = TRUE)
    stop('extraction failed for ', url)
  }
  message('  downloaded + extracted: ', out_dir, '/  (',
          length(list.files(out_dir)), ' files)')
  invisible('downloaded')
}

setwd(dest)

manifest = list()
add_row = function(path, url, year, fresh) {
  manifest[[path]] <<- data.frame(
    path      = path,
    url       = url,
    year      = year,
    bytes     = file.size(path),
    md5       = unname(tools::md5sum(path)),
    retrieved = if (fresh) format(Sys.Date()) else NA,
    stringsAsFactors = FALSE
  )
}

for (year in years) {
  message('=== ', year, ' ===')

  if (year <= 2013) {
    status = fetch_archive_year(year)
    if (status != 'missing') {
      zip_url = file.path(BASE, archive_zip(sprintf('%02d', year %% 100), year))
      for (f in list.files(sprintf('archive/%d', year), full.names = TRUE)) {
        add_row(f, zip_url, year, fresh = (status == 'downloaded'))
      }
    }
  } else {
    for (tg in modern_targets(year)) {
      status = fetch_file(tg$url, tg$to)
      if (file.exists(tg$to)) {
        add_row(tg$to, tg$url, year, fresh = (status == 'downloaded'))
      }
    }
  }
}

# Pub 16 PDFs on irs-prior are named by REVISION year (p16--2019.pdf covers
# tax year 2016, etc.); try every revision year from the first one published
# (2019) through today and let the 404 skip handle the rest
for (rev in 2019:as.integer(format(Sys.Date(), '%Y'))) {
  url = file.path(BASE_PRIOR, sprintf('p16--%d.pdf', rev))
  to  = sprintf('docs/pub16/p16--%d.pdf', rev)
  status = fetch_file(url, to)
  if (file.exists(to)) add_row(to, url, rev, fresh = (status == 'downloaded'))
}

#----------------
# Write manifest
#----------------

mf = do.call(rbind, manifest)
if (file.exists('manifest.csv')) {
  old = utils::read.csv('manifest.csv', stringsAsFactors = FALSE)
  mf$retrieved = ifelse(is.na(mf$retrieved),
                        old$retrieved[match(mf$path, old$path)],
                        mf$retrieved)
  # keep rows for files outside this run's year range that are still on disk,
  # so a subset-year run does not shrink the manifest
  keep = old[!(old$path %in% mf$path) & file.exists(old$path), ]
  mf = rbind(mf, keep)
}
mf = mf[order(mf$path), ]
utils::write.csv(mf, 'manifest.csv', row.names = FALSE)
message('Wrote manifest.csv (', nrow(mf), ' files)')
