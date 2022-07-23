FROM 84codes/crystal:1.5.0-alpine AS builder
# FROM 84codes/crystal:1.5.0-alpine

RUN apk add --no-cache yaml-static

COPY shard.yml shard.lock /build/
WORKDIR /build
RUN shards

COPY . /build/

RUN shards build controller --production --static # --release

# Artifact

FROM scratch

COPY --from=builder /build/bin/controller /

ENTRYPOINT ["/controller"]
