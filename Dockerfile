FROM debian:latest

RUN apt-get update && apt-get install ca-certificates libsqlite3-dev -y

ADD ./librust.so /app/librust.so
ADD bin/s5_server.exe /app/bin/server

ENV DOCKER=TRUE

EXPOSE 5050

ENTRYPOINT ["/app/bin/server"]

