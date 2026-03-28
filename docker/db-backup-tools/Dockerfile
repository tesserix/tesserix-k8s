FROM google/cloud-sdk:slim AS gcloud

FROM alpine:3.20

# PostgreSQL 16 client tools
RUN apk add --no-cache \
    postgresql16-client \
    bash \
    curl \
    gzip \
    zstd \
    python3 \
    gcompat

# MongoDB tools (mongodump, mongorestore) + mongosh
RUN apk add --no-cache --repository=https://dl-cdn.alpinelinux.org/alpine/edge/community \
    mongodb-tools \
    mongosh

# Copy gsutil and gcloud from the official cloud-sdk image
COPY --from=gcloud /usr/lib/google-cloud-sdk /usr/lib/google-cloud-sdk
RUN ln -s /usr/lib/google-cloud-sdk/bin/gsutil /usr/local/bin/gsutil \
    && ln -s /usr/lib/google-cloud-sdk/bin/gcloud /usr/local/bin/gcloud

ENTRYPOINT ["/bin/bash"]
