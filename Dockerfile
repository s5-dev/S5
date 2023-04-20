FROM debian:latest

RUN apt-get update && apt-get install ca-certificates libsqlite3-dev zip git llvm curl gnupg \
build-essential pkg-config libssl-dev libclang-dev -y

RUN curl -sSL https://dl.google.com/linux/linux_signing_key.pub | apt-key add -
RUN curl -sSL https://storage.googleapis.com/download.dartlang.org/linux/debian/dart_stable.list \
    > /etc/apt/sources.list.d/dart_stable.list
RUN apt-get update && apt-get install -y dart
RUN apt-get update && apt-get install -y build-essential
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y
ENV PATH=$PATH:/root/.cargo/bin:/usr/lib/dart/bin

WORKDIR /app

COPY . .

RUN cd rust && cargo build --release && cd .. && mkdir -p bin && \
    cp rust/target/release/librust.so /bin/librust.so && \
    dart compile exe bin/s5_server.dart && \
    chmod +x bin/s5_server.exe

ENV DOCKER=TRUE

EXPOSE 5050

ENTRYPOINT ["/app/bin/s5_server.exe"]
