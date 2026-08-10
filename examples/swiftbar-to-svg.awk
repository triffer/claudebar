# swiftbar-to-svg.awk — draw SwiftBar plugin output as an SVG.
#
# Reads the lines of one SwiftBar section on stdin and writes an SVG to stdout.
#   -v panel=board   the dropdown: light rounded panel, one line per row
#   -v panel=bar     the menu bar item: dark strip, one line
#
# Only the params claudebar actually emits are honoured — size, color,
# disabled, alternate, and the `---` separator. Anything else (bash=, href=,
# param1=…) describes what a click does, which a picture cannot show anyway.
#
# Run it under LC_ALL=C: nchars() counts characters by subtracting UTF-8
# continuation bytes from a byte length, which only holds if awk is counting
# bytes. Doing it that way keeps the script working on the one-byte awks as
# well as the multibyte ones.

function xesc(s) {
  gsub(/&/, "\\&amp;",  s)
  gsub(/</, "\\&lt;",   s)
  gsub(/>/, "\\&gt;",   s)
  return s
}

function nchars(s,   t, cont) {
  t = s
  cont = gsub(/[\200-\277]/, "", t)
  return length(s) - cont
}

# Width of a line, in points. Charging every character the same width does not
# work here: an emoji is about two and a half times an average letter, and the
# menu bar title is a third emoji by character count — flat-rate it and the text
# spills straight out of the strip. So characters are priced by their UTF-8
# length, which sorts them well enough: 4 bytes is an emoji, 3 is a box-drawing
# or punctuation glyph near a full em, 2 is a narrow accent, 1 is a letter.
#
# A variation selector (U+FE0F) would be charged as its own 3-byte glyph; none
# of the board's icons carry one today, and a theme that adds one only makes the
# panel slightly too wide.
function textw(s, size,   t, c4, c3, c2, ascii) {
  t = s; c4 = gsub(/[\360-\367]/, "", t)
  t = s; c3 = gsub(/[\340-\357]/, "", t)
  t = s; c2 = gsub(/[\302-\337]/, "", t)
  ascii = nchars(s) - c4 - c3 - c2
  return size * (ascii * 0.49 + c2 * 0.35 + c3 * 0.9 + c4 * 1.25)
}

function param(params, key,   pat) {
  pat = key "=[^ ]+"
  if (match(params, pat)) return substr(params, RSTART + length(key) + 1, RLENGTH - length(key) - 1)
  return ""
}

BEGIN {
  FG       = "#1d1d1f"   # ordinary menu text
  DISABLED = "#8e8e93"   # SwiftBar greys out disabled=true rows
  # A menu bar extra is packed tighter than a menu row, and only the dropdown
  # casts a shadow that needs room around it.
  PAD_X    = (panel == "bar") ? 8 : 17
  PAD_Y    = 10
  MARGIN   = (panel == "bar") ? 6 : 10
  SEP_H    = 12
  n        = 0
  width    = 0
  height   = PAD_Y * 2
}

{
  line = $0
  if (line == "---") {
    n++; kind[n] = "sep"; height += SEP_H
    next
  }

  text = line; params = ""
  cut = index(line, " | ")
  if (cut > 0) { text = substr(line, 1, cut - 1); params = substr(line, cut + 3) }

  # Alternate rows are the ⌥-held variant of the row above; they are never on
  # screen at the same time as the one we already drew.
  if (params ~ /alternate=true/) next

  size = param(params, "size") + 0
  if (size == 0) size = 13
  color = param(params, "color")
  if (color == "") color = (params ~ /disabled=true/) ? DISABLED : FG

  n++
  kind[n] = "row"; body[n] = text; fsize[n] = size; fill[n] = color
  height += size + 10
  w = PAD_X * 2 + textw(text, size)
  if (w > width) width = w
}

END {
  if (panel == "bar") { render_bar(); exit }
  render_board()
}

function render_board(   i, y, lh, baseline, W, H) {
  W = int(width + 0.5)
  H = int(height + 0.5)
  printf "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" role=\"img\">\n", \
    W + MARGIN * 2, H + MARGIN * 2, W + MARGIN * 2, H + MARGIN * 2
  header()
  printf "  <rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" rx=\"12\" fill=\"url(#panel)\" stroke=\"#dcd8d4\" filter=\"url(#shadow)\"/>\n", \
    MARGIN, MARGIN, W, H

  y = MARGIN + PAD_Y
  for (i = 1; i <= n; i++) {
    if (kind[i] == "sep") {
      printf "  <line x1=\"%d\" y1=\"%.1f\" x2=\"%d\" y2=\"%.1f\" stroke=\"#dedad6\" stroke-width=\"1\"/>\n", \
        MARGIN + 8, y + SEP_H / 2, MARGIN + W - 8, y + SEP_H / 2
      y += SEP_H
      continue
    }
    lh = fsize[i] + 10
    baseline = y + (lh + fsize[i] * 0.72) / 2
    printf "  <text x=\"%d\" y=\"%.1f\" font-size=\"%d\" fill=\"%s\">%s</text>\n", \
      MARGIN + PAD_X, baseline, fsize[i], fill[i], xesc(body[i])
    y += lh
  }
  print "  </g>"
  print "</svg>"
}

function render_bar(   W, H, baseline) {
  H = 24
  W = int(PAD_X * 2 + textw(body[1], fsize[1]) + 0.5)
  baseline = MARGIN + (H + fsize[1] * 0.72) / 2
  printf "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" role=\"img\">\n", \
    W + MARGIN * 2, H + MARGIN * 2, W + MARGIN * 2, H + MARGIN * 2
  header()
  printf "  <rect x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\" rx=\"6\" fill=\"url(#bar)\"/>\n", MARGIN, MARGIN, W, H
  printf "  <text x=\"%d\" y=\"%.1f\" font-size=\"%d\" fill=\"#f5f5f7\">%s</text>\n", \
    MARGIN + PAD_X, baseline, fsize[1], xesc(body[1])
  print "  </g>"
  print "</svg>"
}

# The font stack ends in the emoji families on purpose: the state dots and the
# 📦 sandbox marker are text, so they are drawn by whatever colour emoji font
# the reader's browser has rather than being baked in as paths.
function header() {
  print "  <defs>"
  print "    <linearGradient id=\"panel\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">"
  print "      <stop offset=\"0\" stop-color=\"#fbfaf9\"/><stop offset=\"1\" stop-color=\"#f1eeeb\"/>"
  print "    </linearGradient>"
  print "    <linearGradient id=\"bar\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">"
  print "      <stop offset=\"0\" stop-color=\"#4c4c51\"/><stop offset=\"1\" stop-color=\"#3e3e43\"/>"
  print "    </linearGradient>"
  print "    <filter id=\"shadow\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\">"
  print "      <feDropShadow dx=\"0\" dy=\"2\" stdDeviation=\"4\" flood-color=\"#000\" flood-opacity=\"0.18\"/>"
  print "    </filter>"
  print "  </defs>"
  print "  <g font-family=\"-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, 'Apple Color Emoji', 'Segoe UI Emoji', 'Noto Color Emoji', sans-serif\">"
}
