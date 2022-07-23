FROM 84codes/crystal:1.5.0-alpine AS builder

COPY shard.yml shard.lock /build/
WORKDIR /build
RUN shards

COPY . /build/

RUN shards build controller --production --release

# Artifact

FROM scratch

COPY --from=builder /build/bin/controller /

CMD ["/controller"]
