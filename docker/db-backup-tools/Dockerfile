FROM google/cloud-sdk:slim

# PostgreSQL 16 client
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
       wget gnupg lsb-release \
    && echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
       > /etc/apt/sources.list.d/pgdg.list \
    && wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
    && apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends postgresql-client-16 \
    && rm -rf /var/lib/apt/lists/*

# MongoDB tools (mongodump, mongorestore, mongosh)
RUN wget -qO- https://www.mongodb.org/static/pgp/server-7.0.asc | apt-key add - \
    && echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/debian $(lsb_release -cs)/mongodb-org/7.0 main" \
       > /etc/apt/sources.list.d/mongodb-org-7.0.list \
    && apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends \
       mongodb-database-tools \
       mongodb-mongosh \
    && rm -rf /var/lib/apt/lists/*

# zstd for PostgreSQL backup compression
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends zstd \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/bin/bash"]
