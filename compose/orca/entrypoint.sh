#!/usr/bin/env bash
#
# Entrypoint for the orca container. Runs as root only long enough to fix up
# ownership of the bind-mounted home directory and to stage the dind client
# certificates somewhere the service account can read, then drops to the
# unprivileged `orca` user and execs the Orca binary.
#
# Dropping privileges matters here: upstream's headless guide notes that
# running the app as root forces Chromium's --no-sandbox, which disables a
# real security boundary on a listener that is reachable beyond localhost.

set -euo pipefail

ORCA_UID="$(id -u orca)"
ORCA_GID="$(id -g orca)"
ORCA_HOME="$(getent passwd orca | cut -d: -f6)"

export HOME="$ORCA_HOME"

mkdir -p "$ORCA_HOME"

# /home/orca is a bind mount from /opt/dockerdata/orca/home, which Docker
# creates root-owned on first run. Recurse only when the top-level owner is
# actually wrong — a settled install holds worktrees and agent state, and an
# unconditional `chown -R` would walk all of it on every restart.
if [ "$(stat -c %u "$ORCA_HOME")" != "$ORCA_UID" ]; then
  echo "entrypoint: taking ownership of $ORCA_HOME (uid $ORCA_UID)" >&2
  chown -R "$ORCA_UID:$ORCA_GID" "$ORCA_HOME"
fi

# The dind sidecar publishes its client certificates on a shared volume that
# is mounted read-only here. dockerd writes the client key root-owned, so it
# is copied to a location the service account owns rather than read in place.
if [ -n "${DOCKER_CERT_PATH:-}" ] && [ -d /certs/client ]; then
  mkdir -p "$DOCKER_CERT_PATH"
  for pem in ca.pem cert.pem key.pem; do
    if [ -f "/certs/client/$pem" ]; then
      cp -f "/certs/client/$pem" "$DOCKER_CERT_PATH/$pem"
    fi
  done
  chown -R "$ORCA_UID:$ORCA_GID" "$DOCKER_CERT_PATH"
  chmod 0700 "$DOCKER_CERT_PATH"
  [ -f "$DOCKER_CERT_PATH/key.pem" ] && chmod 0400 "$DOCKER_CERT_PATH/key.pem"
fi

# Orca starts its own Xvfb on :99 when no DISPLAY is set, so none is exported
# here. LIBGL_ALWAYS_SOFTWARE keeps Electron off the absent GPU.
#
# --no-sandbox, and why it is the safer of the two available options.
#
# Chromium's zygote cannot create the user namespace its sandbox needs inside
# a container ("Failed to move to new namespace ... errno = Operation not
# permitted", followed by a FATAL in zygote_host_impl_linux.cc). Ubuntu
# 24.04's AppArmor restriction on unprivileged user namespaces applies to the
# container too, so a setuid chrome-sandbox helper does not rescue it either.
# There are exactly two ways out:
#
#   1. Loosen the container: seccomp=unconfined, plus apparmor=unconfined on
#      this host. That weakens the container-to-HOST syscall boundary.
#   2. --no-sandbox. That weakens the renderer-to-CONTAINER boundary.
#
# Upstream's headless guide warns against (2) — correctly, for a normal
# deployment. It is still the right choice here, because of what this
# container is: Orca exists to run agent-authored shell commands as this
# service account. Anything the renderer sandbox would contain, an agent
# terminal can already do by design, so (2) gives up a boundary that is
# already open. (1) gives up a boundary that is genuinely still closed — the
# one keeping arbitrary agent code inside the container. Trading the intact
# boundary away to preserve the moot one would be backwards.
#
# The flag must precede the subcommand: `orca-ide serve --no-sandbox` parses
# as an argument to serve and never reaches Chromium.
exec setpriv --reuid="$ORCA_UID" --regid="$ORCA_GID" --init-groups \
  /opt/Orca/orca-ide --no-sandbox "$@"
