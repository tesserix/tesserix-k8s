# Custom GitHub Actions Runner for ARC
# Extends the official runner with tools needed by tesserix-k8s workflows
FROM ghcr.io/actions/actions-runner:latest

USER root

# Versions
ARG HELM_VERSION=3.14.0
ARG TERRAFORM_VERSION=1.6.0
ARG KUBECONFORM_VERSION=0.6.4
ARG GO_VERSION=1.26.0
ARG NODE_VERSION=20.18.2

# System packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    wget \
    git \
    make \
    jq \
    unzip \
    gnupg \
    lsb-release \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
    python3 \
    python3-pip \
    python3-venv \
    docker.io \
    && rm -rf /var/lib/apt/lists/*

# Helm
RUN curl -fsSL https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz \
    | tar xz -C /usr/local/bin --strip-components=1 linux-amd64/helm

# Terraform
RUN curl -fsSL https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin \
    && rm /tmp/terraform.zip

# Google Cloud SDK + kubectl + gke-gcloud-auth-plugin
RUN curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | tee /etc/apt/sources.list.d/google-cloud-sdk.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    google-cloud-cli \
    google-cloud-cli-gke-gcloud-auth-plugin \
    kubectl \
    && rm -rf /var/lib/apt/lists/*

# kubeconform
RUN curl -fsSL https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz \
    | tar xz -C /usr/local/bin kubeconform

# Trivy
RUN curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

# Python tools (checkov, yamllint, helm-docs)
RUN pip3 install --no-cache-dir --break-system-packages \
    checkov \
    yamllint

# helm-docs
RUN curl -fsSL https://github.com/norwoodj/helm-docs/releases/latest/download/helm-docs_$(curl -s https://api.github.com/repos/norwoodj/helm-docs/releases/latest | jq -r .tag_name | sed 's/^v//')_Linux_x86_64.tar.gz \
    | tar xz -C /usr/local/bin helm-docs

# Go — pre-install into actions tool cache so setup-go@v5 skips download
RUN mkdir -p /opt/hostedtoolcache/go/${GO_VERSION}/x64 && \
    curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz \
    | tar xz -C /opt/hostedtoolcache/go/${GO_VERSION}/x64 --strip-components=1 && \
    touch /opt/hostedtoolcache/go/${GO_VERSION}/x64.complete
ENV PATH="/opt/hostedtoolcache/go/${GO_VERSION}/x64/bin:${PATH}"

# Node.js — pre-install into actions tool cache so setup-node@v4 skips download
# Use .tar.gz instead of .tar.xz because xz is not available in the base image
RUN mkdir -p /opt/hostedtoolcache/node/${NODE_VERSION}/x64 && \
    curl -fsSL https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz \
    | tar xz -C /opt/hostedtoolcache/node/${NODE_VERSION}/x64 --strip-components=1 && \
    touch /opt/hostedtoolcache/node/${NODE_VERSION}/x64.complete
ENV PATH="/opt/hostedtoolcache/node/${NODE_VERSION}/x64/bin:${PATH}"

# Switch back to runner user
USER runner

# Verify installations
RUN helm version --short && \
    terraform version && \
    gcloud version --format=json | jq -r '.["Google Cloud SDK"]' && \
    kubectl version --client --short 2>/dev/null || kubectl version --client && \
    kubeconform -v && \
    trivy --version && \
    checkov --version && \
    yamllint --version && \
    helm-docs --version && \
    go version && \
    node --version && \
    npm --version
