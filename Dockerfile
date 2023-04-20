FROM debian:latest

RUN apt-get update && apt-get install ca-certificates libsqlite3-dev zip -y

RUN apt-get install curl unzip -y \
  && curl --silent "https://get.sdkman.io" | bash \
  && chmod +x "$HOME/.sdkman/bin/sdkman-init.sh" \
  && /bin/bash -c "source $HOME/.sdkman/bin/sdkman-init.sh && sdk install dart" \
  && /bin/bash -c "source $HOME/.cargo/env && cargo install --version=1.55.0 cargo-buildx"

WORKDIR /app

COPY . .

RUN cargo build --release && \
    cp rust/target/release/librust.so /app/librust.so && \
    dart compile exe bin/s5_server.dart && \
    chmod +x bin/s5_server.exe

ENV DOCKER=TRUE

EXPOSE 5050

ENTRYPOINT ["/app/bin/s5_server.exe"]
