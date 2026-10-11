FROM rust:1.99.0-bookworm
ENV CARGO_BUILD_JOBS=2 CARGO_PROFILE_DEV_DEBUG=0 CARGO_PROFILE_TEST_DEBUG=0
RUN rustup component add clippy && apt-get update && apt-get install -y --no-install-recommends iproute2 iptables nginx openssl && rm -rf /var/lib/apt/lists/*
WORKDIR /lab
COPY Cargo.toml Cargo.lock ./
COPY src ./src
COPY tests ./tests
COPY examples ./examples
COPY network-lab/run.sh ./network-lab/run.sh
RUN cargo test --locked --test network_faults --no-run && cargo build --locked --examples
ENTRYPOINT ["sh", "network-lab/run.sh"]
