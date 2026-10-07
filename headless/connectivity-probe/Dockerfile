FROM rust:1.99.0-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN --mount=type=cache,id=syncstr-probe-registry,target=/usr/local/cargo/registry \
    --mount=type=cache,id=syncstr-probe-target,target=/src/target \
    cargo build --release --locked && cp target/release/syncstr-connectivity-probe /probe
FROM debian:bookworm-slim
COPY --from=build /probe /usr/local/bin/syncstr-connectivity-probe
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/syncstr-connectivity-probe"]
