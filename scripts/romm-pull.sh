#!/usr/bin/env bash
#
# Incrementally mirror a RomM library to a local folder.
#
# This runs on the *client* (laptop), not on the homelab host — copy it over.
# RomM has no first-party Linux desktop client and no WebDAV, so the supported
# way to pull a library down is the REST API with a Client API Token.
#
# Layout written locally mirrors RomM's own: $ROMM_DEST/<platform-slug>/<file>.
# Re-runs are cheap: a ROM is skipped when the local file already matches the
# size RomM reports. Multi-file ROMs arrive as a zip, whose size can't be
# compared against the source, so those are skipped on mere existence — delete
# the local zip to force a re-pull.
#
# Usage:
#   ROMM_URL=https://romm.dev.example.com ./romm-pull.sh            # everything
#   ROMM_URL=https://romm.dev.example.com ./romm-pull.sh n64 snes   # some platforms
#
# Config (environment):
#   ROMM_URL         base URL of the instance                      (required)
#   ROMM_TOKEN       rmm_… Client API Token                        (or ROMM_TOKEN_FILE)
#   ROMM_TOKEN_FILE  file holding the token   (default ~/.config/romm/token)
#   ROMM_DEST        local library root       (default ~/roms)
#   ROMM_DRY_RUN     set to 1 to list what would be pulled, and stop
#
# Create the token in the web UI under Settings → API tokens. Read-only scopes
# are enough; the token is shown exactly once. Prefer the token *file* over
# ROMM_TOKEN so it never reaches your shell history.

set -euo pipefail

ROMM_URL="${ROMM_URL:-}"
ROMM_DEST="${ROMM_DEST:-$HOME/roms}"
ROMM_TOKEN_FILE="${ROMM_TOKEN_FILE:-$HOME/.config/romm/token}"
ROMM_TOKEN="${ROMM_TOKEN:-}"
ROMM_DRY_RUN="${ROMM_DRY_RUN:-0}"

if [[ -z "$ROMM_TOKEN" && -r "$ROMM_TOKEN_FILE" ]]; then
  ROMM_TOKEN="$(tr -d '[:space:]' < "$ROMM_TOKEN_FILE")"
fi

[[ -n "$ROMM_URL" ]] || { echo "romm-pull: ROMM_URL is not set" >&2; exit 1; }
if [[ -z "$ROMM_TOKEN" ]]; then
  echo "romm-pull: no token — set ROMM_TOKEN or write one to $ROMM_TOKEN_FILE" >&2
  exit 1
fi
ROMM_URL="${ROMM_URL%/}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# The token is fed to curl through a config file on stdin rather than an -H
# argument, so it never shows up in `ps` output.
curl_auth() {
  printf 'header = "Authorization: Bearer %s"\n' "$ROMM_TOKEN" |
    curl --silent --show-error --location --fail -K - "$@"
}

urlencode() {
  python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"
}

# --- build the index --------------------------------------------------------
# One TSV line per ROM: id, platform slug, source size, multi-file flag,
# download name. Paginated because /api/roms caps a page at 10000 entries.

INDEX="$TMP_DIR/index.tsv"
: > "$INDEX"

PAGE_SIZE=500
offset=0
total=0

while :; do
  url="$ROMM_URL/api/roms?limit=$PAGE_SIZE&offset=$offset"
  url+="&with_char_index=false&with_filter_values=false&with_files=false"

  if ! curl_auth -o "$TMP_DIR/page.json" "$url"; then
    echo "romm-pull: request to $ROMM_URL failed — check the URL, and that the" >&2
    echo "           token is valid and has not expired (401/403)." >&2
    exit 1
  fi

  read -r total count < <(
    python3 - "$TMP_DIR/page.json" "$INDEX" "$@" <<'PY'
import json, sys

page = json.load(open(sys.argv[1]))
wanted = set(sys.argv[3:])
items = page["items"]
written = 0

with open(sys.argv[2], "a") as out:
    for rom in items:
        if wanted and rom["platform_slug"] not in wanted:
            continue
        multi = bool(rom["has_multiple_files"])
        # Multi-file ROMs are folders server-side and stream back as a zip.
        name = rom["fs_name"] + (".zip" if multi else "")
        out.write("\t".join((
            str(rom["id"]),
            rom["platform_slug"],
            str(rom["fs_size_bytes"]),
            "1" if multi else "0",
            name,
        )) + "\n")
        written += 1

print(page["total"], len(items))
PY
  )

  offset=$((offset + PAGE_SIZE))
  (( count > 0 )) || break        # defensive: never spin on an empty page
  (( offset < total )) || break
done

selected=$(wc -l < "$INDEX")
echo "romm-pull: $total ROMs on the server, $selected selected -> $ROMM_DEST"

if [[ "$ROMM_DRY_RUN" == "1" ]]; then
  cut -f2,5 "$INDEX" | sort
  exit 0
fi

# --- pull -------------------------------------------------------------------

downloaded=0
skipped=0

while IFS=$'\t' read -r id slug size multi name; do
  dest_dir="$ROMM_DEST/$slug"
  dest="$dest_dir/$name"

  if [[ -f "$dest" ]]; then
    if [[ "$multi" == "1" ]] || [[ "$(stat -c %s "$dest")" == "$size" ]]; then
      skipped=$((skipped + 1))
      continue
    fi
  fi

  mkdir -p "$dest_dir"
  echo "  ↓ $slug/$name"
  # Download to .part and rename, so an interrupted run never leaves a
  # truncated file that the size check would later have to catch.
  curl_auth --progress-bar -o "$dest.part" \
    "$ROMM_URL/api/roms/$id/content/$(urlencode "$name")"
  mv "$dest.part" "$dest"
  downloaded=$((downloaded + 1))
done < "$INDEX"

echo "romm-pull: $downloaded downloaded, $skipped already current"
