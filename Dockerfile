# Custom supabase/supavisor image on Debian 12 (Bookworm)
# Reason: upstream uses Bullseye (Debian 11, EOL), which has 22+ CRITICAL CVEs
# including exim4 RCE CVE-2026-40687 that have no fix in Bullseye.
#
# Tracks: supabase/supavisor v2.9.7
# Registry: ghcr.io/mahue/supavisor-bookworm

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=26.2.5.21
ARG DEBIAN_VERSION=bookworm-20260518-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# --- Build stage ---
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && apt-get install -y \
    build-essential \
    git \
    curl \
    cmake \
    libclang-dev \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock VERSION ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY native native

RUN mix compile

COPY config/runtime.exs config/

COPY rel rel
RUN mix release supavisor

# --- Runtime stage ---
# Use Debian 12 (Bookworm) slim — avoids all Bullseye CRITICAL CVEs including
# exim4 RCE CVE-2026-40687. Only installs runtime dependencies; no build tools.
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && apt-get upgrade -y && apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses6 \
    locales \
    curl \
    htop \
    postgresql-client \
    tini \
  && apt-get install -y --only-upgrade libgnutls30 \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && apt-mark showmanual | sort

# Explicitly verify exim4 is NOT installed (security gate)
RUN ! dpkg -l exim4 2>/dev/null | grep -q "^ii"

# Note: perl/libperl5.36/perl-modules-5.36 cannot be removed — postgresql-client
# depends on them. CVE-2026-42496 and CVE-2026-8376 are suppressed via .trivyignore
# per CTO decision 2026-06-04 (no fix available in Debian 12 either).

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/supavisor ./

COPY limits.sh /app/limits.sh

ENV RLIMIT_NOFILE=100000
ENTRYPOINT ["/usr/bin/tini", "-s", "-g", "--", "/app/limits.sh"]
CMD ["/app/bin/server"]

ENV ECTO_IPV6=true
ENV ERL_AFLAGS="-proto_dist inet6_tcp"
