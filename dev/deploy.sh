#!/usr/bin/env bash
# Install the committed state of this repo into the live Omarchy plugin.
# Run this only when the work is finished and tested in the dev harness. It
# restarts the shell once at the end so the new version actually shows.
#
# The live plugin folder is expected to be a git checkout (what
# `omarchy plugin add <url>` makes); it is fast-forwarded to this repo's HEAD.
# Uncommitted edits in the live folder are dropped only when they are an
# exact copy of a commit that HEAD already contains (files copied in by
# hand); anything else stops the deploy. A plain copy (no .git) is moved to
# ~/Work/backups/<plugin-id>.<timestamp> and replaced by a checkout.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="$(jq -r .id "$repo/manifest.json")"
live="${OMARCHY_PLUGIN_DIR:-$HOME/.config/omarchy/plugins}/$id"
branch="$(git -C "$repo" branch --show-current)"
url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"

[[ -n $branch ]] || { echo "Check out a branch first (deploy installs that branch, HEAD is detached)." >&2; exit 1; }
[[ -z $(git -C "$repo" status --porcelain) ]] || { echo "Commit your changes first (deploy installs HEAD)." >&2; exit 1; }
omarchy plugin validate "$repo"
"$repo/dev/run.sh" check >/dev/null || { "$repo/dev/run.sh" check; echo "QML does not compile; not deploying." >&2; exit 1; }

if [[ -d $live/.git ]]; then
  git -C "$live" fetch -q "$repo" "$branch"
  dirty=$(git -C "$live" diff --name-only HEAD)
  if [[ -n $dirty ]]; then
    # Files copied in by hand from a commit that $branch already contains
    # (the live tree matches that commit for those paths) are safe to reset.
    match=""
    for c in $(git -C "$live" rev-list HEAD..FETCH_HEAD); do
      if git -C "$live" diff --quiet "$c" -- $dirty; then match=$c; break; fi
    done
    if [[ -n $match ]]; then
      git -C "$live" checkout -q -- $dirty
      echo "Live edits in $(echo $dirty) match $(git -C "$live" log --oneline -1 "$match"); reset them before fast-forwarding."
    else
      echo "The live plugin has edits that are not in $branch:" >&2
      git -C "$live" diff --stat FETCH_HEAD -- $dirty >&2
      echo "Bring them into $repo first (or discard them), then deploy again." >&2
      exit 1
    fi
  fi
  git -C "$live" merge --ff-only -q FETCH_HEAD
  # Follow a branch rename (master -> main) so the live checkout matches.
  [[ $(git -C "$live" branch --show-current) == "$branch" ]] || git -C "$live" branch -m "$branch"
  # Keep `omarchy plugin update` pointing at GitHub once the repo has a remote.
  [[ -n $url ]] && git -C "$live" remote set-url origin "$url"
else
  # Build the checkout outside the plugins folder first (the shell would load
  # a second copy there), so a failed clone leaves the live plugin untouched;
  # then swap it in.
  new="$HOME/Work/backups/.$id.new"
  rm -rf "$new"
  mkdir -p "$(dirname "$new")"
  git clone -q --branch "$branch" "$repo" "$new"
  [[ -n $url ]] && git -C "$new" remote set-url origin "$url"
  if [[ -d $live ]]; then
    backup="$HOME/Work/backups/$id.$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$(dirname "$backup")"
    mv "$live" "$backup"
    # If the swap fails, put the plain copy back.
    trap '[[ -d $live ]] || mv "$backup" "$live"' EXIT
    echo "Backed up the plain copy at $live to $backup"
  fi
  mv "$new" "$live"
  trap - EXIT
fi
echo "Deployed $(git -C "$repo" log --oneline -1) to $live"

# The shell's hot reload is not reliable for plugins (the old version can stay
# on screen), so finish with one restart. Skip with NO_RESTART=1.
if [[ ${NO_RESTART:-0} != 1 ]]; then
  omarchy restart shell >/dev/null 2>&1 || true
  echo "Shell restarted: the new version is live."
fi
