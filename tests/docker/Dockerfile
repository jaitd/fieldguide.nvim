# The Linux half of the test matrix. `verify` has two sandbox backends and a
# developer on macOS can only run one of them, so this image exists to exercise
# the other: bwrap, on a real Linux kernel, against the same task list.
#
#   mise run test:linux
#
# Nothing here is a deployment target. It is a place to run `mise run test`.

# 22 is the oldest node fieldguide supports. CI also builds this with the LTS
# from .node-version, through FIELDGUIDE_NODE_VERSION in run.sh.
ARG NODE_VERSION=22
FROM node:${NODE_VERSION}-bookworm-slim

# bubblewrap is the point of the image. python3 is what tests/bridge.sh asserts
# its JSON with; git is the shadow repo; xz-utils and curl unpack Neovim.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       bubblewrap ca-certificates curl git procps python3 xz-utils \
  && rm -rf /var/lib/apt/lists/*

# Neovim from the release tarball rather than apt: Debian is a long way behind
# the 0.12 this needs, and the tarball is the same build a user would install.
ARG NVIM_VERSION=v0.12.4
ARG TARGETARCH
RUN set -eux; \
  case "$TARGETARCH" in \
    arm64) arch=arm64 ;; \
    amd64) arch=x86_64 ;; \
    *) echo "no Neovim tarball for TARGETARCH=$TARGETARCH" >&2; exit 1 ;; \
  esac; \
  curl -fsSL "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${arch}.tar.gz" \
    | tar -xz -C /opt; \
  ln -s "/opt/nvim-linux-${arch}/bin/nvim" /usr/local/bin/nvim; \
  nvim --version | head -1

# mise, so the container runs the same task list as the host rather than a
# second copy of it that can drift.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
  && mise --version
ENV MISE_TRUSTED_CONFIG_PATHS=/work

# Tools from mise.toml (stylua) at build time, so the run needs no network.
WORKDIR /work
COPY mise.toml /work/mise.toml
RUN mise install

# A config for the bridge tests to answer from. They run against "this
# machine's real config" on purpose — the docs resolver's whole claim is that
# it reads what is installed — so the image needs one, with real plugins at
# real revisions. Installed at build time; the tests themselves stay offline.
COPY tests/docker/config /root/.config/nvim
RUN nvim --headless "+Lazy! install" +qa \
  && nvim --headless -c 'lua io.write(("%d plugins\n"):format(vim.tbl_count(require("lazy.core.config").plugins)))' -c 'qa!'

# The repo is mounted over /work at run time, read-only.
CMD ["mise", "run", "test"]
