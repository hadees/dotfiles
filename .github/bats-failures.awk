# Reads bats' TAP output (stderr merged) and, at the end, prints a digest of the
# failed tests, one workflow annotation per failure, and a job summary.
# Used by every CI step that runs bats:
#   bats ... 2>&1 | awk -f .github/bats-failures.awk -f .github/bats-progress.awk
# Inputs: standard input; optional awk variables mode (empty or rerun), maxann,
# maxlines, maxsum; environment GITHUB_STEP_SUMMARY.
# It must come before bats-progress.awk on the command line, must never print a
# stream line or assign to $0 (bats-progress.awk owns the print rule), and all its
# variable names begin bf_.
#
# A failure record starts at a "not ok <n> " line and ends at the next result line
# or at end of input. A green run prints nothing and opens no file. POSIX awk only.

BEGIN {
  if (maxann == "") maxann = 9
  if (maxlines == "") maxlines = 60
  if (maxsum == "") maxsum = 25
  maxann += 0
  maxlines += 0
  maxsum += 0
  bf_sum = ENVIRON["GITHUB_STEP_SUMMARY"]
  bf_rerun = (mode == "rerun")
}

{
  bf_l = $0
  sub(/^\[[0-9]+\/[0-9]+\] /, "", bf_l)
  if (bf_l ~ /^1\.\.[0-9]+$/) {
    if (bf_plan == "") bf_plan = substr(bf_l, 4)
  } else if (bf_l ~ /^(not )?ok [0-9]+ /) bf_result(bf_l)
  else if (bf_on) bf_line(bf_l)
}

END {
  bf_close()
  bf_p = (bf_plan == "") ? "?" : bf_plan
  if (bf_rerun) {
    if (bf_plan != "") bf_digest()
  } else if (bf_nrec > 0) bf_digest()
  else if (bf_plan != "" && bf_seen < bf_plan + 0) {
    print "===== bats: " bf_seen " of " bf_p " results arrived ====="
    print "::error title=bats ended early::" bf_seen " of " bf_p " results arrived"
  }
}

# A result line: ends the open record, counts the result, opens a record for a
# failure, and in rerun mode remembers the passed and skipped names.
function bf_result(l,   t, bad, skip, ms) {
  bf_close()
  bf_seen++
  bad = (l ~ /^not ok /)
  t = l
  sub(/^(not )?ok /, "", t)
  match(t, /^[0-9]+/)
  bf_nn = substr(t, 1, RLENGTH)
  t = substr(t, RLENGTH + 2)
  skip = (!bad && t ~ / # skip/)
  if (skip) sub(/ # skip.*$/, "", t)
  ms = ""
  if (match(t, / in [0-9]+ms$/)) {
    ms = substr(t, RSTART + 4, RLENGTH - 6)
    t = substr(t, 1, RSTART - 1)
  }
  if (bad) {
    bf_on = 1
    bf_nrec++
    bf_num[bf_nrec] = bf_nn
    bf_name[bf_nrec] = t
    bf_ms[bf_nrec] = ms
    bf_nfr[bf_nrec] = 0
    bf_cmd[bf_nrec] = ""
    bf_st = 0
    bf_nraw = 0
  } else if (bf_rerun) {
    if (skip) bf_skp[++bf_nskp] = t
    else bf_flk[++bf_nflk] = t
  }
}

# One line of the open record. bf_st: 0 first line, 1 in the trace, 2 after the
# trace, 3 no trace.
function bf_line(l,   r, s, p, n, f) {
  r = bf_nrec
  if (bf_st == 0) bf_st = (l ~ /^# \(/) ? 1 : 3
  if (bf_st == 1) {
    if (match(l, /in (test )?file [^,]+, line [0-9]+/)) {
      s = substr(l, RSTART, RLENGTH)
      sub(/^in (test )?file /, "", s)
      match(s, /, line [0-9]+$/)
      p = substr(s, 1, RSTART - 1)
      n = substr(s, RSTART + 7)
      f = ""
      if (match(l, /from function `[^']*'/)) f = substr(l, RSTART + 15, RLENGTH - 16)
      if (++bf_nfr[r] == 1) {
        bf_hp[r] = p
        bf_hl[r] = n
        bf_hf[r] = f
      }
      bf_lp[r] = p
      bf_ll[r] = n
      bf_lf[r] = f
    }
    if (l ~ /\)$/) bf_st = 2
    return
  }
  if (bf_st == 2 && bf_cmd[r] == "" && l ~ /^#   `/) {
    bf_cmd[r] = substr(l, 5)
    return
  }
  if (l ~ /^#/) {
    sub(/^# ?/, "", l)
    bf_raw[++bf_nraw] = l
  }
}

# Close the open record: fold runs of identical output lines, then cap the result.
function bf_close(   r, i, k, nf, head, j) {
  if (!bf_on) return
  bf_on = 0
  r = bf_nrec
  nf = 0
  for (i = 1; i <= bf_nraw; i += k) {
    for (k = 1; i + k <= bf_nraw && bf_raw[i + k] == bf_raw[i]; k++) ;
    bf_fold[++nf] = bf_raw[i]
    if (k > 1) bf_fold[++nf] = "... " (k - 1) " more lines identical to the one above"
  }
  if (nf <= maxlines) {
    for (i = 1; i <= nf; i++) bf_o[r, i] = bf_fold[i]
    bf_no[r] = nf
    return
  }
  head = maxlines - 10
  if (head < 0) head = 0
  j = 0
  for (i = 1; i <= head; i++) bf_o[r, ++j] = bf_fold[i]
  bf_o[r, ++j] = "... " (nf - head - 10) " lines left out (the whole output is above, at \"not ok " bf_num[r] "\")"
  for (i = nf - 9; i <= nf; i++) bf_o[r, ++j] = bf_fold[i]
  bf_no[r] = j
}

function bf_at(r,   s) {
  if (bf_nfr[r] == 0) return "at (no location in the output)"
  s = "at " bf_lp[r] ":" bf_ll[r]
  if (bf_nfr[r] == 1) {
    if (bf_lf[r] != "") s = s ", in " bf_lf[r]
  } else if (bf_hf[r] != "") s = s ", in " bf_hf[r] " (" bf_hp[r] ":" bf_hl[r] ")"
  return s
}

function bf_block(r,   s, i) {
  s = "not ok " bf_num[r] " " bf_name[r]
  if (bf_ms[r] != "") s = s " (" bf_ms[r] "ms)"
  print s
  print "  " bf_at(r)
  if (bf_cmd[r] != "") print "  " bf_cmd[r]
  for (i = 1; i <= bf_no[r]; i++) print "  | " bf_o[r, i]
  print ""
}

# Workflow-command escaping, as the Actions toolkit does it.
function bf_msg(s) {
  gsub(/%/, "%25", s)
  gsub(/\r/, "%0D", s)
  gsub(/\n/, "%0A", s)
  return s
}
function bf_prop(s) {
  s = bf_msg(s)
  gsub(/:/, "%3A", s)
  gsub(/,/, "%2C", s)
  return s
}
function bf_html(s) {
  gsub(/&/, "\\&amp;", s)
  gsub(/</, "\\&lt;", s)
  gsub(/>/, "\\&gt;", s)
  return s
}

function bf_w(s) { print s >> bf_sum }

function bf_summary(   i, k, n, s) {
  if (bf_rerun) bf_w("### bats re-run: " bf_nrec " failed twice, " bf_nflk + 0 " flaky, " bf_nskp + 0 " skipped")
  else bf_w("### bats: " bf_nrec " of " bf_p " failed")
  n = (bf_nrec > maxsum) ? maxsum : bf_nrec
  for (i = 1; i <= n; i++) {
    s = "- **" (bf_rerun ? "failed twice" : bf_num[i]) "** " bf_html(bf_name[i])
    if (bf_nfr[i] > 0) s = s ": <code>" bf_html(bf_lp[i] ":" bf_ll[i]) "</code>"
    bf_w(s)
    if (bf_cmd[i] != "" || bf_no[i] > 0) {
      bf_w("<details><summary><code>" bf_html(bf_cmd[i] == "" ? "output" : bf_cmd[i]) "</code></summary>")
      bf_w("<pre>")
      for (k = 1; k <= bf_no[i]; k++) bf_w(bf_html(bf_o[i, k]))
      bf_w("</pre>")
      bf_w("</details>")
    }
  }
  if (bf_nrec > maxsum) bf_w("- and " (bf_nrec - maxsum) " more")
  for (i = 1; i <= bf_nflk; i++) bf_w("- **flaky (passed on re-run)** " bf_html(bf_flk[i]))
  for (i = 1; i <= bf_nskp; i++) bf_w("- **skipped on re-run** " bf_html(bf_skp[i]))
  close(bf_sum)
}

function bf_digest(   i, s, nloc, shown, over, fshown, fover) {
  if (bf_rerun) print "===== bats re-run: " bf_nrec " failed twice, " bf_nflk + 0 " passed on re-run (flaky), " bf_nskp + 0 " skipped on re-run, of " bf_p " ====="
  else print "===== bats failures: " bf_nrec " of " bf_p " ====="
  for (i = 1; i <= bf_nrec; i++) {
    bf_block(i)
    if (bf_nfr[i] == 0) nloc++
  }
  for (i = 1; i <= bf_nflk; i++) print "flaky: " bf_flk[i]
  for (i = 1; i <= bf_nskp; i++) print "skipped on re-run: " bf_skp[i]
  shown = (bf_nrec > maxann) ? maxann - 1 : bf_nrec
  over = bf_nrec - shown
  fshown = (bf_nflk > maxann) ? maxann - 1 : bf_nflk
  fover = bf_nflk - fshown
  print "results: " bf_seen " of " bf_p
  print "annotations: " shown + (over > 0) " written, " over " over the limit of " maxann
  if (bf_rerun) print "flaky warnings: " fshown + (fover > 0) " written, " fover " over the limit of " maxann
  print "without a location: " nloc + 0
  if (bf_sum != "") {
    bf_summary()
    print "job summary: written"
  } else print "job summary: not written (GITHUB_STEP_SUMMARY is unset)"
  print "===== end bats " (bf_rerun ? "re-run" : "failures") " ====="
  for (i = 1; i <= shown; i++) {
    s = bf_msg("not ok " bf_num[i] " " bf_name[i] (bf_cmd[i] == "" ? "" : "\n" bf_cmd[i]))
    print "::error " (bf_nfr[i] > 0 ? "file=" bf_prop(bf_lp[i]) ",line=" bf_prop(bf_ll[i]) "," : "") "title=" (bf_rerun ? "bats failed twice" : "bats failed") "::" s
  }
  if (over > 0) print "::error title=" (bf_rerun ? "bats failed twice" : "bats failed") "::" over " more failed tests are in the digest and the job summary"
  for (i = 1; i <= fshown; i++) print "::warning title=bats flaky (passed on re-run)::" bf_msg(bf_flk[i])
  if (fover > 0) print "::warning title=bats flaky (passed on re-run)::" fover " more flaky tests are in the digest and the job summary"
}
