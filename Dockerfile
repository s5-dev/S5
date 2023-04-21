FROM dart:latest

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
    && cp rust/target/release/librust.so /bin/librust.so \
    && dart compile exe bin/s5_server.dart \
    && chmod +x bin/s5_server.exe

ENV DOCKER=TRUE

EXPOSE 5050

ENTRYPOINT ["/app/bin/s5_server.exe"]
