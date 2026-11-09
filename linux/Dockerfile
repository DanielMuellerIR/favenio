FROM rust:1.99.1-bookworm AS rust
FROM swift:6.2.1-noble
COPY --from=rust /usr/local/cargo /usr/local/cargo
COPY --from=rust /usr/local/rustup /usr/local/rustup
ENV RUSTUP_HOME=/usr/local/rustup PATH=/usr/local/cargo/bin:$PATH CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_LINKER=clang
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libgtk-4-dev pkg-config python3 openssl libssl-dev ca-certificates \
    xvfb xauth imagemagick dbus-x11 fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*
ENV RUSTFLAGS="-Clink-arg=-fuse-ld=lld"
WORKDIR /src
