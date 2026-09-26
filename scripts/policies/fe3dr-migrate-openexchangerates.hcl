# Dedicated operator-issued token; TTL <=15m. No update/delete/list/admin grants.
path "kv/data/homechef/homechef-api/fe3dr-openexchangerates-app-id" {
  capabilities = ["create", "read"]
}
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
path "auth/token/revoke-self" {
  capabilities = ["update"]
}
