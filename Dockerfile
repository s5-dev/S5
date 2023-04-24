FROM dart:latest AS builder

# Get dependencies
RUN \
    export DEBIAN_FRONTEND=noninteractive \
    && apt-get update -y \
    && apt-get upgrade -y \
    && apt-get install --no-install-recommends -y \
    ca-certificates \
    libsqlite3-dev \
    zip \
    git \
    llvm \
    curl \
    gnupg \
    build-essential \
    pkg-config \
    libssl-dev \
    libclang-dev \
    apt-transport-https \
    wget


RUN curl https://sh.rustup.rs -sSf | bash -s -- -y 
ENV PATH="/root/.cargo/bin:$PATH"
RUN echo 'export PATH="/root/.cargo/bin:$PATH"' >> ~/.profile

WORKDIR /app

COPY . .

# And build
RUN dart pub get \
    && cd rust \
    && cargo build --release \
    && cd .. \
    && mkdir -p bin \
    && cp rust/target/release/librust.so . \
    && dart compile exe bin/s5_server.dart -o  bin/s5_server \
    && chmod +x bin/s5_server \
    && mkdir -p /runtime/lib \
    && ldd bin/s5_server | grep "=> /" | awk '{print $3}' | xargs -I '{}' cp -v '{}' /runtime/lib/ \
    && ldd librust.so | grep "=> /" | awk '{print $3}' | xargs -I '{}' cp -v '{}' /runtime/lib/

# Copy build to fresh image because without doing this the image
# is like 5.6GB lol (it's now like 22MB!)
FROM scratch
COPY --from=builder /runtime/ /
COPY --from=builder /app/librust.so /app/librust.so
COPY --from=builder /app/bin/s5_server /app/bin/
ENV DOCKER=TRUE

# Start server.
EXPOSE 5050
CMD ["/app/bin/s5_server"]