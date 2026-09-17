#!/usr/bin/env bash
# Run the suite on Linux, where `verify` uses bwrap instead of seatbelt.
#
#   mise run test:linux                 # the whole task list
#   mise run test:linux -- mise run test:verify
#   mise run test:linux -- bash         # a shell in there
#
# The repo is mounted read-only: the container is for running the tests, not
# for editing the tree, and a read-only mount is also how root in here stops
# leaving root-owned files in your checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${FIELDGUIDE_LINUX_IMAGE:-fieldguide-linux-test}"
NODE_VERSION="$(cat "$ROOT/.node-version")"

if ! docker info >/dev/null 2>&1; then
  echo "docker is not running — start Docker Desktop or OrbStack first" >&2
  exit 1
fi

# A Mac that has slept comes back with the VM's clock behind the host's, and
# the first symptom is apt refusing every Debian release file as "not valid
# yet" — which reads like a broken mirror rather than a wrong clock. Say so.
skew=$(( $(date -u +%s) - $(docker run --rm "$IMAGE" date -u +%s 2>/dev/null || \
           docker run --rm "node:$NODE_VERSION-bookworm-slim" date -u +%s 2>/dev/null || echo 0) ))
# Minutes of drift are normal and cost nothing; hours are what breaks the apt
# step of a build. A warning either way — a stale clock is never a reason to
# refuse to run tests that are already built.
if [[ "$skew" -gt 1800 || "$skew" -lt -1800 ]]; then
  echo "note: the container clock is $((skew / 60))min behind the host's." >&2
  echo "      harmless for the tests; if the image build fails on apt saying a" >&2
  echo "      release file is \"not valid yet\", restart Docker/OrbStack to resync." >&2
fi

docker build --quiet -t "$IMAGE" -f "$ROOT/tests/docker/Dockerfile" \
  --build-arg "NODE_VERSION=$NODE_VERSION" "$ROOT" >/dev/null

# bwrap has to build the same sandbox in here that it builds on a real Linux
# box, and a container denies it three things by default:
#
#   seccomp=unconfined   the default profile refuses the namespace syscalls
#   SYS_ADMIN            without it, "Creating new namespace failed"
#   NET_ADMIN            --unshare-net brings loopback up inside the new netns,
#                        and without this that fails with RTM_NEWADDR
#
# Less than a full --privileged, and still enough that what runs under test is
# the shipping sandbox rather than a weakened stand-in.
#
# No arguments means the image's own CMD (`mise run test`). Passing "$@"
# unguarded under `set -u` would hand docker an empty argv instead, which it
# runs as an empty command and reports as a silent success.
run=(docker run --rm
  --security-opt seccomp=unconfined
  --security-opt apparmor=unconfined
  --cap-add SYS_ADMIN
  --cap-add NET_ADMIN
  -v "$ROOT:/work:ro"
  "$IMAGE")
exec "${run[@]}" "$@"
