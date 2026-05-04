# syntax=docker/dockerfile:1.7

# ---- builder ----
FROM rust:1-bookworm AS builder
WORKDIR /build

# Pre-cache deps so a code-only change doesn't redownload the world.
COPY Cargo.toml Cargo.lock* ./
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs && \
    cargo build --release && \
    rm -rf src target/release/deps/tring_tring* target/release/tring-tring*

COPY src ./src
COPY migrations ./migrations
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/build/target \
    cargo build --release --locked && \
    cp target/release/tring-tring /usr/local/bin/tring-tring

# ---- litestream (download per arch) ----
FROM debian:bookworm-slim AS litestream
ARG LITESTREAM_VERSION=0.3.13
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN ARCH="$(dpkg --print-architecture)" && \
    curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-${ARCH}.deb" \
      -o /tmp/litestream.deb && \
    dpkg -i /tmp/litestream.deb && \
    rm /tmp/litestream.deb

# ---- runtime ----
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates tini sqlite3 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/tring-tring /usr/local/bin/tring-tring
COPY --from=litestream /usr/bin/litestream /usr/local/bin/litestream
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Persistent volume for SQLite + WAL files. See ADR-0009.
VOLUME ["/data"]

EXPOSE 8080
ENV LISTEN_ADDR=0.0.0.0:8080 \
    DATABASE_URL=sqlite:///data/db.sqlite?mode=rwc \
    RUST_LOG=tring_tring=info,info

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
