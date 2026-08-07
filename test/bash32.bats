#!/usr/bin/env bats
# /bin/bash on macOS is bash 3.2, and that is what runs claudebar on the
# machines it targets. CI runs bash 5, which accepts things 3.2 does not — so
# the rules 3.2 imposes are checked here by scanning the sources instead.
#
# Tests are arrange / act / assert, separated by blank lines.

load helper

setup()    { claudebar_setup; }
teardown() { claudebar_teardown; }

# Every shell source in the repo, whatever it is called and wherever it lands.
# Whole-line comments are dropped from the result: this file and the installer
# both spell the hazard out in prose, and a rule you cannot describe without
# tripping it is a rule nobody will document.
scan() { # $1: extended regex
  bash -c 'find "$1" -name "*.sh" -not -path "*/node_modules/*" -not -path "*/.git/*" \
             -print0 | LC_ALL=C xargs -0 grep -nHE "$2" \
             | grep -vE "^[^:]+:[0-9]+:[[:space:]]*#"' _ "$REPO_ROOT" "$1"
}

@test "no variable is expanded straight into a non-ASCII character" {
  # bash 3.2 counts a UTF-8 lead byte as a name character, so "$VERSION…"
  # expands the variable "VERSION…" — unbound, and under set -u that aborts the
  # script. This shipped once, in the installer's own banner. ${VERSION}… is
  # the fix, and the ellipsis, the arrows and the emoji in these files mean the
  # hazard is one edit away at all times.
  run scan "$(printf '\\$[A-Za-z_][A-Za-z0-9_]*[^\t -~]')"

  [ -z "$output" ] || { echo "brace these expansions:"; echo "$output"; false; }
}

@test "no associative arrays" {
  # bash 3.2 has none; `declare -A` is a syntax error there, not a warning
  run scan '(declare|local|typeset) +-[a-zA-Z]*A'

  [ -z "$output" ] || { echo "bash 3.2 has no associative arrays:"; echo "$output"; false; }
}
