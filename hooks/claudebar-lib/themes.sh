# shellcheck shell=bash
# claudebar/lib/themes.sh — icon sets for the menu bar and dropdown.
#
# Every theme maps the same five roles to a glyph: marker (the item that
# identifies the board itself), permission, waiting, ready, working. Adding a
# theme is one more case arm here — nothing in claudebar.3s.sh names a glyph
# directly, so a new theme never touches the renderer.

claudebar_theme_icon() { # $1: theme  $2: role
  case "$1" in
    cow)
      case "$2" in
        marker)     printf '🐮' ;;
        permission) printf '🐽' ;;
        ready)      printf '🥛' ;;
        waiting)    printf '🟠' ;;
        working)    printf '🔵' ;;
        *)          printf '⚪️' ;;
      esac
      ;;
    *)
      case "$2" in
        marker)     printf '✳' ;;
        permission) printf '🔴' ;;
        waiting)    printf '🟠' ;;
        ready)      printf '🟢' ;;
        working)    printf '🔵' ;;
        *)          printf '⚪️' ;;
      esac
      ;;
  esac
}
