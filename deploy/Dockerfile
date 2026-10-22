# Commerce service image. The build stage installs the package and its
# dependencies; the runtime stage carries the compiled result and a
# writable /data volume for the SQLite store.
#
# Build:  docker build -t commerce-service -f deploy/Dockerfile .
# Run:    docker run -d --name commerce \
#           -p 127.0.0.1:8080:8080 \
#           -v commerce-data:/data \
#           -v $PWD/secrets:/run/secrets:ro \
#           --env-file deploy/commerce.env \
#           commerce-service
#
# Terminate: docker stop (SIGTERM). The store is crash-safe by design;
# a restart re-claims expired leases and re-projects from the journal.

FROM racket/racket:9.3

WORKDIR /src

# Dependency layer: Permit tracks its published main.
RUN raco pkg install --auto --no-docs --name permit \
      https://github.com/turinglambdaai/permit.git

# Package layer: install from the full source tree, compile the service.
COPY info.rkt /src/info.rkt
COPY commerce /src/commerce
COPY commerce-doc /src/commerce-doc
COPY examples /src/examples
RUN raco pkg install --auto --no-docs --link --name commerce /src \
 && raco make /src/examples/service.rkt

# Runtime layout
RUN mkdir -p /data
VOLUME /data

ENV COMMERCE_DB_PATH=/data/commerce.sqlite
ENV COMMERCE_PORT=8080
ENV COMMERCE_LISTEN_IP=0.0.0.0
ENV COMMERCE_POLL_SECONDS=2

EXPOSE 8080
CMD ["racket", "/src/examples/service.rkt"]
