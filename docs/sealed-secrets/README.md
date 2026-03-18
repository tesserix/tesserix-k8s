# Sealed Secrets Guide

Sealed Secrets allows you to encrypt Kubernetes Secrets so they can be safely stored in Git repositories. Only the Sealed Secrets controller running in the cluster can decrypt them.

## Prerequisites

### Install kubeseal CLI

**macOS:**
```bash
brew install kubeseal
```

**Linux:**
```bash
KUBESEAL_VERSION="0.27.2"
wget "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz
sudo mv kubeseal /usr/local/bin/
rm kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz
```

**Windows:**
```bash
# Using scoop
scoop install kubeseal
```

## Cluster Configuration

- **Controller Name:** `sealed-secrets`
- **Controller Namespace:** `kube-system`
- **Certificate Location:** `sealed-secrets-cert.pem` (project root)

## Quick Start

### 1. Fetch the Public Certificate (Optional)

The certificate is already saved at `sealed-secrets-cert.pem`. To fetch a fresh copy:

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  > sealed-secrets-cert.pem
```

### 2. Create a Regular Secret

```bash
# From literals
kubectl create secret generic my-secret \
  --namespace=my-namespace \
  --from-literal=username=admin \
  --from-literal=password=supersecret \
  --dry-run=client -o yaml > my-secret.yaml

# From file
kubectl create secret generic my-tls-secret \
  --namespace=my-namespace \
  --from-file=tls.crt=./cert.pem \
  --from-file=tls.key=./key.pem \
  --dry-run=client -o yaml > my-tls-secret.yaml
```

### 3. Seal the Secret

**Using the local certificate:**
```bash
kubeseal --cert sealed-secrets-cert.pem \
  --format yaml \
  < my-secret.yaml \
  > my-sealed-secret.yaml
```

**Or directly from the cluster:**
```bash
kubeseal \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  --format yaml \
  < my-secret.yaml \
  > my-sealed-secret.yaml
```

### 4. Apply the SealedSecret

```bash
kubectl apply -f my-sealed-secret.yaml
```

The controller will automatically create the decrypted Secret in the target namespace.

## Common Use Cases

### Database Credentials

```bash
# Create the secret
kubectl create secret generic postgresql-password \
  --namespace=database \
  --from-literal=postgresql-password='MySecurePassword123!' \
  --dry-run=client -o yaml | \
kubeseal --cert sealed-secrets-cert.pem --format yaml \
  > sealed-postgresql-password.yaml
```

### GHCR Image Pull Secret

```bash
# Create docker-registry secret
kubectl create secret docker-registry ghcr-secret \
  --namespace=ecommerce \
  --docker-server=ghcr.io \
  --docker-username=tesserix \
  --docker-password='ghp_YourGitHubPAT' \
  --docker-email=devops@tesserix.app \
  --dry-run=client -o yaml | \
kubeseal --cert sealed-secrets-cert.pem --format yaml \
  > sealed-ghcr-secret.yaml
```

### API Keys and Tokens

```bash
kubectl create secret generic api-keys \
  --namespace=global-svc \
  --from-literal=resend-api-key='re_123456789' \
  --from-literal=verification-api-key='vk_987654321' \
  --from-literal=encryption-key='32-character-encryption-key!!' \
  --dry-run=client -o yaml | \
kubeseal --cert sealed-secrets-cert.pem --format yaml \
  > sealed-api-keys.yaml
```

### Kargo Credentials

```bash
# GHCR credentials for Kargo
kubectl create secret generic ghcr-image-creds \
  --namespace=tesseract-hub-devtest \
  --from-literal=repoURL='^ghcr\.io/tesserix/.*' \
  --from-literal=repoURLIsRegex='true' \
  --from-literal=username=tesserix \
  --from-literal=password='ghp_YourGitHubPAT' \
  --dry-run=client -o yaml | \
kubeseal --cert sealed-secrets-cert.pem --format yaml \
  > sealed-ghcr-image-creds.yaml

# Add the Kargo label manually to the sealed secret
# Edit the file and add under metadata.labels:
#   kargo.akuity.io/cred-type: image
```

## Scopes

SealedSecrets support different scopes that control where they can be decrypted:

### Strict (Default)
Secret is bound to both name and namespace. Most secure.
```bash
kubeseal --scope strict ...
```

### Namespace-wide
Secret can be decrypted in any secret name within the namespace.
```bash
kubeseal --scope namespace-wide ...
```

### Cluster-wide
Secret can be decrypted anywhere in the cluster. Least secure.
```bash
kubeseal --scope cluster-wide ...
```

## Updating a SealedSecret

To update a sealed secret, you need to:

1. Create a new regular secret with the updated values
2. Re-seal it with kubeseal
3. Apply the new SealedSecret

```bash
# Update the secret
kubectl create secret generic my-secret \
  --namespace=my-namespace \
  --from-literal=password=newsecretpassword \
  --dry-run=client -o yaml | \
kubeseal --cert sealed-secrets-cert.pem --format yaml \
  > my-sealed-secret.yaml

# Apply (this will update the existing secret)
kubectl apply -f my-sealed-secret.yaml
```

## Verifying a SealedSecret

Check if the controller has processed your SealedSecret:

```bash
# List all sealed secrets
kubectl get sealedsecrets -A

# Check the status
kubectl describe sealedsecret my-sealed-secret -n my-namespace

# Verify the decrypted secret exists
kubectl get secret my-secret -n my-namespace
```

## Troubleshooting

### Secret Not Being Created

Check the controller logs:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=sealed-secrets
```

### Certificate Mismatch

If you get decryption errors, the certificate might have been rotated:
```bash
# Fetch the new certificate
kubeseal --fetch-cert \
  --controller-name=sealed-secrets \
  --controller-namespace=kube-system \
  > sealed-secrets-cert.pem

# Re-seal all secrets with the new certificate
```

### Wrong Namespace

SealedSecrets are namespace-bound by default. Ensure the namespace in the secret matches where you're applying it.

## Best Practices

1. **Never commit regular Secrets** - Only commit SealedSecrets to Git
2. **Use strict scope** - Unless you have a specific reason for namespace-wide or cluster-wide
3. **Backup the controller's private key** - For disaster recovery:
   ```bash
   kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key-backup.yaml
   ```
4. **Rotate secrets periodically** - Create new SealedSecrets and apply them
5. **Use separate secrets per concern** - Don't bundle unrelated credentials

## File Organization

Recommended structure for sealed secrets in your repo:

```
tesserix-k8s/
├── sealed-secrets/
│   ├── database/
│   │   └── sealed-postgresql-password.yaml
│   ├── ecommerce/
│   │   └── sealed-ghcr-secret.yaml
│   ├── global-svc/
│   │   └── sealed-api-keys.yaml
│   ├── kargo/
│   │   └── sealed-ghcr-image-creds.yaml
│   └── onboarding/
│       └── sealed-verification-secrets.yaml
└── sealed-secrets-cert.pem
```

## References

- [Sealed Secrets GitHub](https://github.com/bitnami-labs/sealed-secrets)
- [Sealed Secrets Documentation](https://sealed-secrets.netlify.app/)
