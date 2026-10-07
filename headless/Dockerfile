FROM rust:1.99.0-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
ARG SYNCSTR_FEATURES=""
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY scripts ./scripts
RUN --mount=type=cache,id=syncstr-rust-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=syncstr-rust-target-amd64,target=/src/target \
    cargo build --release --locked --features "$SYNCSTR_FEATURES" && \
    cp target/release/syncstr-headless /syncstr-headless && \
    python3 scripts/collect_licenses.py /licenses "$SYNCSTR_FEATURES"

FROM debian:bookworm-slim
COPY --from=build /syncstr-headless /usr/local/bin/syncstr-headless
COPY --from=build /licenses /usr/share/syncstr/licenses
USER 1000:1000
EXPOSE 8443
ENTRYPOINT ["/usr/local/bin/syncstr-headless"]
CMD ["serve", "--data", "/data", "--identity", "/identity", "--listen", "0.0.0.0:8443"]
