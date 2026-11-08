# shellcheck shell=bash
# Tiny message catalog for the CLI.
#
# Catalogs live in i18n/cli/<lang>.json as flat {"key": "text"} objects with
# %1..%9 placeholders. English is always loaded first, then the base language
# (pt for pt-BR), then the exact language, so missing keys fall back cleanly.
# The language follows Omarchy's own setting (~/.config/omarchy/language) and
# falls back to $LANG on a plain Arch box.

declare -gA MSG=()
I18N_LANG="en"

i18n_detect_language() {
  local file="${OMARCHY_LANGUAGE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/language}" code=""
  [[ -f $file ]] && code=$(head -n 1 "$file" | tr -d '[:space:]')
  if [[ -z $code ]]; then
    code=${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}
    code=${code%%.*}
    code=${code%%@*}
    code=${code/_/-}
  fi
  [[ $code == C || $code == POSIX || -z $code ]] && code=en
  printf '%s' "$code"
}

# i18n_load <catalog-dir> [lang]
i18n_load() {
  local dir=$1 lang=${2:-} base f k v
  [[ -n $lang ]] || lang=$(i18n_detect_language)
  base=${lang%%-*}
  for f in en "$base" "$lang"; do
    [[ -f $dir/$f.json ]] || continue
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do
      MSG[$k]=$v
    done < <(jq -j 'to_entries[] | "\(.key)\u0000\(.value)\u0000"' "$dir/$f.json" 2>/dev/null)
  done
  I18N_LANG=$lang
}

# t <key> [arg1 arg2 ...]  — prints the translated string with %N substituted.
t() {
  local key=$1 s i=1 a
  shift
  s=${MSG[$key]:-$key}
  for a in "$@"; do
    s=${s//"%$i"/$a}
    ((i++))
  done
  printf '%s' "$s"
}
