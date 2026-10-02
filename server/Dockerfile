FROM rust:1.98-bookworm AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/target/release/syncstr-upload /usr/local/bin/syncstr-upload
USER 1000:1000
ENV SYNCSTR_BIND=0.0.0.0:4545
EXPOSE 4545
ENTRYPOINT ["syncstr-upload"]
