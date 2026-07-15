#!/usr/bin/env bash
#
# Offline validation harness for this repo. Generates throwaway .env files
# from secrets/*.env.example into a temp dir (no real secrets are read, the
# working tree is never touched), validates every compose stack, the
# Caddyfile, and cross-file invariants, then prints a per-check summary.
# Exits non-zero if any check fails; WARN lines are informational.
#
# Needs: docker (with compose v2) and python3. shellcheck/yamllint are used
# from PATH when installed, otherwise via their Docker images.

# shellcheck disable=SC2317,SC2329  # check_* functions are invoked indirectly via run_check (code differs by shellcheck version)

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 1

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Dummy values for `caddy validate`. The cloudflare plugin rejects tokens
# that don't look like real 40-char API tokens, so the shape matters.
DUMMY_DOMAIN="example.com"
DUMMY_CF_TOKEN="0000000000000000000000000000000000000000"
DUMMY_CS_KEY="dummy-bouncer-key"

# Image name matches the runtime build in compose/caddy/compose.yaml so the
# already-built image is reused on the host; CI builds it from the Dockerfile.
CADDY_IMAGE="caddy-cloudflare"

STACKS=()
for d in compose/*/; do
  STACKS+=("$(basename "$d")")
done

# Stack -> env example template. cloudflared intentionally has none (a
# locally-managed tunnel carries no env-var secrets); the navidrome file
# name typo (.navidrom.env) is intentional — the real symlink points there.
env_example_for() {
  case "$1" in
    cloudflared) echo "" ;;
    navidrome)   echo "secrets/.navidrom.env.example" ;;
    *)           echo "secrets/.$1.env.example" ;;
  esac
}

# Copy each stack's compose.yaml next to a dummy .env generated from its
# example template, so `docker compose config` interpolates without the real
# secrets/ symlinks. Values left empty in a template (VAR=) get a filler so
# interpolation never produces an empty string where a path is expected.
stage_stacks() {
  local stack example
  for stack in "${STACKS[@]}"; do
    mkdir -p "$WORK_DIR/stacks/$stack"
    cp "compose/$stack/compose.yaml" "$WORK_DIR/stacks/$stack/compose.yaml"
    example="$(env_example_for "$stack")"
    if [[ -n "$example" && -f "$example" ]]; then
      sed -E 's/^([A-Za-z_][A-Za-z0-9_]*=)$/\1dummy/' "$example" \
        > "$WORK_DIR/stacks/$stack/.env"
    fi
    printf '%s\t%s\n' "$stack" "$(env_example_for "$stack")"
  done > "$WORK_DIR/env_map.tsv"
}

# --- checks -----------------------------------------------------------------

check_compose_config() {
  local rc=0 stack out
  for stack in "${STACKS[@]}"; do
    if out=$(docker compose -f "$WORK_DIR/stacks/$stack/compose.yaml" \
        config --format json 2>&1 >"$WORK_DIR/stacks/$stack/config.json"); then
      echo "    ok: compose/$stack/compose.yaml"
      [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/    WARN: /'
    else
      echo "    FAIL: compose/$stack/compose.yaml"
      printf '%s\n' "$out" | sed 's/^/      /'
      rm -f "$WORK_DIR/stacks/$stack/config.json"
      rc=1
    fi
  done
  return "$rc"
}

check_env_completeness() {
  WORK_DIR="$WORK_DIR" python3 - <<'PY'
import os, re, sys

work = os.environ["WORK_DIR"]
# ${VAR}, ${VAR:-def}, ${VAR:?err} … — compose's braced interpolation form
# (the only form used in this repo). A "-" operator means a default exists.
ref_re = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)((?::?[-?+])[^}]*)?\}")
key_re = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=", re.M)

fail = False
for line in open(os.path.join(work, "env_map.tsv")):
    stack, example = line.rstrip("\n").split("\t")
    # drop comment lines (compose does not interpolate them) and $$-escapes
    text = "\n".join(
        l for l in open(f"compose/{stack}/compose.yaml")
        if not l.lstrip().startswith("#")
    ).replace("$$", "")
    refs = {}  # var -> has_default
    for m in ref_re.finditer(text):
        var, op = m.group(1), m.group(2) or ""
        refs[var] = refs.get(var, False) or op.lstrip(":").startswith("-")
    if not example:
        if refs:
            print(f"    FAIL: {stack}: interpolates {sorted(refs)} but has no env example")
            fail = True
        continue
    keys = set(key_re.findall(open(example).read()))
    for var in sorted(refs):
        if var in keys:
            continue
        if refs[var]:
            print(f"    WARN: {stack}: ${{{var}}} missing from {example} (has a default)")
        else:
            print(f"    FAIL: {stack}: ${{{var}}} not defined in {example}")
            fail = True
    unused = sorted(keys - set(refs))
    if unused:
        print(f"    WARN: {example}: not interpolated in compose.yaml "
              f"(may be consumed by the container via env_file): {', '.join(unused)}")

sys.exit(1 if fail else 0)
PY
}

check_caddy_validate() {
  if ! docker image inspect "$CADDY_IMAGE" >/dev/null 2>&1; then
    echo "    building $CADDY_IMAGE from compose/caddy/Dockerfile..."
    if ! docker build -q -t "$CADDY_IMAGE" compose/caddy; then
      echo "    FAIL: could not build $CADDY_IMAGE"
      return 1
    fi
  fi
  local out
  if ! out=$(docker run --rm --network none \
      -v "$REPO_ROOT/compose/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
      -e "DOMAIN=$DUMMY_DOMAIN" \
      -e "CLOUDFLARE_API_TOKEN=$DUMMY_CF_TOKEN" \
      -e "CROWDSEC_BOUNCER_API_KEY=$DUMMY_CS_KEY" \
      "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1); then
    echo "$out" | tail -5 | sed 's/^/    /'
    return 1
  fi
  echo "    ok: Caddyfile is valid"
}

check_caddy_upstreams() {
  WORK_DIR="$WORK_DIR" python3 - <<'PY'
import glob, json, os, re, sys

work = os.environ["WORK_DIR"]
names = set()      # service names + container_names with their own netns
proxied = {}       # names whose netns is borrowed (network_mode: service:X)
for path in glob.glob(os.path.join(work, "stacks", "*", "config.json")):
    services = json.load(open(path)).get("services", {})
    for svc, spec in services.items():
        mode = spec.get("network_mode", "")
        aliases = {svc, spec.get("container_name", svc)}
        if mode.startswith(("service:", "container:")):
            for a in aliases:
                proxied[a] = mode
        else:
            names |= aliases

fail = False
seen = set()
for line in open("compose/caddy/Caddyfile"):
    tokens = line.split()
    if not tokens or tokens[0] != "reverse_proxy":
        continue
    for tok in tokens[1:]:
        if tok == "{":
            break
        host = re.sub(r"^[a-z+]+://", "", tok).split(":")[0]
        if host in seen:
            continue
        seen.add(host)
        if host in proxied:
            print(f"    FAIL: reverse_proxy -> {host}: container runs with "
                  f"network_mode: {proxied[host]} and is not reachable by its own "
                  f"name — route via the container it borrows the netns from")
            fail = True
        elif host not in names:
            print(f"    FAIL: reverse_proxy -> {host}: no compose service or "
                  f"container with that name")
            fail = True
        else:
            print(f"    ok: {host}")

sys.exit(1 if fail else 0)
PY
}

check_autorestic_locations() {
  local sh_locs yml_locs
  sh_locs=$(sed -n 's/^LOCATIONS="\(.*\)"$/\1/p' autorestic/autorestic.sh \
    | tr ' ' '\n' | sort)
  yml_locs=$(awk '/^locations:/{f=1;next} f&&/^[^ ]/{f=0} f&&/^  [A-Za-z0-9_-]+:/{gsub(/[ :]/,"");print}' \
    autorestic/.autorestic.yml | sort)
  if [[ -z "$sh_locs" || -z "$yml_locs" ]]; then
    echo "    FAIL: could not extract locations (script: '$sh_locs' / yml: '$yml_locs')"
    return 1
  fi
  if [[ "$sh_locs" != "$yml_locs" ]]; then
    echo "    FAIL: LOCATIONS in autorestic.sh != locations in .autorestic.yml"
    diff <(echo "$sh_locs") <(echo "$yml_locs") | sed 's/^/      /'
    return 1
  fi
  echo "    ok: $(echo "$sh_locs" | tr '\n' ' ')"
}

check_env_examples_exist() {
  local rc=0 stack example
  for stack in "${STACKS[@]}"; do
    example="$(env_example_for "$stack")"
    [[ -z "$example" ]] && continue
    if [[ -f "$example" ]]; then
      echo "    ok: $stack -> $example"
    else
      echo "    FAIL: $stack has no $example"
      rc=1
    fi
  done
  return "$rc"
}

check_readme_table() {
  local rc=0 stack
  for stack in "${STACKS[@]}"; do
    if grep -q -- "| \*\*$stack\*\*" README.md; then
      echo "    ok: $stack"
    else
      echo "    FAIL: $stack missing from the README service table"
      rc=1
    fi
  done
  return "$rc"
}

# Tracked plus untracked-but-not-ignored, so new files are linted before the
# first `git add`.
repo_files() {
  git ls-files -c -o --exclude-standard "$@" | sort -u
}

check_shellcheck() {
  local files
  mapfile -t files < <(repo_files '*.sh')
  echo "    files: ${files[*]}"
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${files[@]}" | sed 's/^/    /'
    return "${PIPESTATUS[0]}"
  fi
  docker run --rm -v "$REPO_ROOT:/mnt:ro" -w /mnt \
    koalaman/shellcheck:stable "${files[@]}" | sed 's/^/    /'
  return "${PIPESTATUS[0]}"
}

check_yamllint() {
  local files
  mapfile -t files < <(repo_files '*.yml' '*.yaml')
  echo "    files: ${files[*]}"
  if command -v yamllint >/dev/null 2>&1; then
    yamllint "${files[@]}" | sed 's/^/    /'
    return "${PIPESTATUS[0]}"
  fi
  docker run --rm -v "$REPO_ROOT:/code:ro" -w /code \
    pipelinecomponents/yamllint yamllint "${files[@]}" | sed 's/^/    /'
  return "${PIPESTATUS[0]}"
}

# Host-only: single-file/dir bind-mount sources that live outside the repo
# (gitignored config, unbacked data) and that Docker silently replaces with an
# empty *directory* when the source is missing — the failure then hides until
# the next container recreate, because a running container keeps the deleted
# inode open (this is exactly how cloudflared's config.yml and the GeoLite2 DB
# went missing; see CLAUDE.md). Assert each is present AND a regular file, so
# the rot surfaces here instead of on the next `restart-services.sh`.
# Skipped in CI, where these host paths legitimately don't exist.
check_required_host_files() {
  if [[ -n "${CI:-}" ]]; then
    echo "    skipped (CI: host data dirs are not present)"
    return 0
  fi
  local rc=0 f
  local files=(
    /opt/dockerdata/cloudflared/config.yml
    /opt/dockerdata/cloudflared/creds.json
    /opt/dockerdata/caddy/geoip/GeoLite2-City.mmdb
  )
  for f in "${files[@]}"; do
    if [[ -f "$f" ]]; then
      echo "    ok: $f"
    elif [[ -d "$f" ]]; then
      echo "    FAIL: $f is a DIRECTORY — Docker made it from a missing bind-mount"
      echo "          source; restore the file and recreate the mounting container"
      rc=1
    else
      echo "    FAIL: $f is missing — a bind mount depends on it"
      rc=1
    fi
  done
  return "$rc"
}

# Warn-only by design: some services intentionally track :latest.
check_image_pins() {
  WORK_DIR="$WORK_DIR" python3 - <<'PY'
import glob, json, os

for path in sorted(glob.glob(os.path.join(os.environ["WORK_DIR"], "stacks", "*", "config.json"))):
    stack = os.path.basename(os.path.dirname(path))
    for svc, spec in json.load(open(path)).get("services", {}).items():
        if "build" in spec:
            continue  # built locally, tag pinning does not apply
        image = spec.get("image", "")
        tail = image.rsplit("/", 1)[-1]
        tag = tail.split(":", 1)[1] if ":" in tail else ""
        if "@sha256" in image:
            continue
        if not tag:
            print(f"    WARN: {stack}/{svc}: untagged image {image}")
        elif tag == "latest" or tag.startswith("latest-"):
            print(f"    WARN: {stack}/{svc}: unpinned image {image}")
print("    (warnings only — some services intentionally track latest; do not mass-pin)")
PY
}

# --- runner -----------------------------------------------------------------

RESULTS=()
OVERALL=0

run_check() {
  local name="$1" fn="$2"
  printf '\n==> %s\n' "$name"
  if "$fn"; then
    RESULTS+=("PASS  $name")
  else
    RESULTS+=("FAIL  $name")
    OVERALL=1
  fi
}

if ! docker compose version >/dev/null 2>&1; then
  echo "FATAL: docker compose v2 is required" >&2
  exit 1
fi

stage_stacks

run_check "compose config (all stacks)"        check_compose_config
run_check "env completeness (compose vs example)" check_env_completeness
run_check "caddy validate"                     check_caddy_validate
run_check "caddyfile upstreams vs compose"     check_caddy_upstreams
run_check "autorestic locations in sync"       check_autorestic_locations
run_check "env example exists per stack"       check_env_examples_exist
run_check "README service table coverage"      check_readme_table
run_check "required host files present"        check_required_host_files
run_check "shellcheck"                         check_shellcheck
run_check "yamllint"                           check_yamllint
run_check "image pinning report (warn-only)"   check_image_pins

printf '\n================ summary ================\n'
printf '%s\n' "${RESULTS[@]}"
printf '=========================================\n'
if [[ $OVERALL -ne 0 ]]; then
  echo "RESULT: FAIL"
else
  echo "RESULT: PASS"
fi
exit $OVERALL
