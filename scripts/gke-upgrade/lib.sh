#!/usr/bin/env bash
# Shared helpers for the GKE upgrade workflow. Source, don't execute.

log()  { printf '%s %s\n' "$(date -u '+%H:%M:%SZ')" "$*" >&2; }
warn() { printf '%s WARN  %s\n' "$(date -u '+%H:%M:%SZ')" "$*" >&2; }
die()  { printf '%s ERROR %s\n' "$(date -u '+%H:%M:%SZ')" "$*" >&2; return 1; }

summary() { [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; return 0; }

gke_version_parts() {
  local v=$1
  [[ $v =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-gke\.([0-9]+))?$ ]] || return 1
  printf '%s %s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[5]:-0}"
}

gke_minor_num() {
  local parts
  parts=$(gke_version_parts "$1") || return 1
  awk '{print $2}' <<<"$parts"
}

# Prints 1 if $1 > $2, -1 if $1 < $2, 0 if equal. Compares the gke build numerically.
gke_version_cmp() {
  local a b
  a=$(gke_version_parts "$1") || return 1
  b=$(gke_version_parts "$2") || return 1
  local -a av bv
  read -r -a av <<<"$a"
  read -r -a bv <<<"$b"
  local i
  for i in 0 1 2 3; do
    if ((av[i] > bv[i])); then echo 1; return 0; fi
    if ((av[i] < bv[i])); then echo -1; return 0; fi
  done
  echo 0
}

# GKE forbids downgrades and multi-minor jumps; catching it here beats a half-upgraded cluster.
assert_upgrade_path() {
  local from=$1 to=$2
  gke_version_parts "$from" >/dev/null || { die "unparseable current version: $from"; return 1; }
  gke_version_parts "$to" >/dev/null || { die "unparseable target version: $to (want e.g. 1.36.2-gke.2064000)"; return 1; }

  local -a f t
  read -r -a f <<<"$(gke_version_parts "$from")"
  read -r -a t <<<"$(gke_version_parts "$to")"

  [[ "${f[0]}" == "${t[0]}" ]] || { die "major version change ${f[0]} -> ${t[0]} is not supported"; return 1; }
  [[ "$(gke_version_cmp "$to" "$from")" == "-1" ]] && { die "downgrade $from -> $to is not possible on GKE"; return 1; }
  (( t[1] - f[1] > 1 )) && { die "cannot skip minor versions: $from -> $to (go via 1.$((f[1] + 1)).x)"; return 1; }
  return 0
}

assert_node_not_ahead_of_control_plane() {
  local node=$1 control_plane=$2
  [[ "$(gke_version_cmp "$node" "$control_plane")" == "1" ]] &&
    { die "node version $node is ahead of control plane $control_plane"; return 1; }
  return 0
}

# A cordoned-but-Ready node is usually the autoscaler retiring a node, not a fault,
# so it must not block an upgrade. Only a node that is not Ready does.
node_status_class() {
  case "$1" in
    Ready) echo ok ;;
    Ready,SchedulingDisabled) echo warn ;;
    *) echo block ;;
  esac
}

# Lines present in $2 but not $1 — workloads this upgrade broke, ignoring ones already broken.
unhealthy_delta() {
  local before=$1 after=$2
  comm -13 \
    <(printf '%s\n' "$before" | grep -v '^[[:space:]]*$' | sort -u) \
    <(printf '%s\n' "$after" | grep -v '^[[:space:]]*$' | sort -u)
}

# Server-populated or default-valued keys that carry no information for a recreate.
_POOL_IGNORED_KEYS='["etag","selfLink","status","instanceGroupUrls","version","podIpv4CidrSize","kubeletCertInfo","name","initialNodeCount","conditions","updateInfo","bestEffortProvisioning","queuedProvisioning","placementPolicy","etag"]'
_POOL_IGNORED_CONFIG_KEYS='["effectiveCgroupMode","resourceLabels","windowsNodeConfig","bootDisk","metadata","preemptible","serviceAccount","advancedMachineFeatures","shieldedInstanceConfig","loggingConfig","containerdConfig","gcfsConfig","kubeletConfig","linuxNodeConfig","resourceManagerTags","secondaryBootDisks","storagePools","confidentialNodes","fastSocket","nodeImageConfig"]'

# Emits gcloud `node-pools create` flags reproducing a live pool's spec, one per line.
# Fails closed: any config key we cannot faithfully reproduce aborts rather than
# silently creating a pool that differs from the one it replaced.
pool_create_flags() {
  local json=$1

  local unknown
  unknown=$(jq -r --argjson ig "$_POOL_IGNORED_KEYS" '
    [keys[] | select(. as $k | ($ig + ["config","autoscaling","locations","management","maxPodsConstraint","networkConfig","upgradeSettings"]) | index($k) | not)] | join(",")
  ' <<<"$json") || return 1
  [[ -n "$unknown" ]] && { die "node pool has fields this script cannot reproduce: $unknown"; return 1; }

  unknown=$(jq -r --argjson ig "$_POOL_IGNORED_CONFIG_KEYS" '
    (.config // {}) | [keys[] | select(. as $k | ($ig + ["machineType","diskSizeGb","diskType","imageType","labels","spot","taints","tags","accelerators","workloadMetadataConfig","sandboxConfig","oauthScopes","minCpuPlatform","localSsdCount","diskEncryptionKey","bootDiskKmsKey","reservationAffinity","gvnic"]) | index($k) | not)] | join(",")
  ' <<<"$json") || return 1
  [[ -n "$unknown" ]] && { die "node pool config has fields this script cannot reproduce: $unknown"; return 1; }

  jq -r '
    def emit($f): select($f != null and $f != "") | $f;
    def taint_effect: {"NO_SCHEDULE":"NoSchedule","PREFER_NO_SCHEDULE":"PreferNoSchedule","NO_EXECUTE":"NoExecute"}[.] // .;

    (.config // {}) as $c |
    (.autoscaling // {}) as $a |
    (.management // {}) as $m |
    (.networkConfig // {}) as $n |
    [
      emit("--machine-type=\($c.machineType)"),
      (if $c.diskType     then "--disk-type=\($c.diskType)" else empty end),
      (if $c.diskSizeGb   then "--disk-size=\($c.diskSizeGb)" else empty end),
      (if $c.imageType    then "--image-type=\($c.imageType)" else empty end),
      (if $c.minCpuPlatform then "--min-cpu-platform=\($c.minCpuPlatform)" else empty end),
      (if $c.localSsdCount then "--local-ssd-count=\($c.localSsdCount)" else empty end),
      (if $c.spot == true then "--spot" else empty end),
      (if ($c.labels // {}) | length > 0
        then "--node-labels=" + ([$c.labels | to_entries[] | "\(.key)=\(.value)"] | sort | join(","))
        else empty end),
      (if ($c.taints // []) | length > 0
        then "--node-taints=" + ([$c.taints[] | "\(.key)=\(.value):\(.effect | taint_effect)"] | join(","))
        else empty end),
      (if ($c.tags // []) | length > 0 then "--tags=" + ($c.tags | join(",")) else empty end),
      (if ($c.oauthScopes // []) | length > 0 then "--scopes=" + ($c.oauthScopes | join(",")) else empty end),
      (if ($c.accelerators // []) | length > 0
        then ($c.accelerators[] |
          "--accelerator=type=\(.acceleratorType),count=\(.acceleratorCount)" +
          (if .gpuDriverInstallationConfig.gpuDriverVersion
            then ",gpu-driver-version=\(.gpuDriverInstallationConfig.gpuDriverVersion | ascii_downcase)"
            else "" end))
        else empty end),
      (if $c.workloadMetadataConfig.mode then "--workload-metadata=\($c.workloadMetadataConfig.mode)" else empty end),
      (if $c.sandboxConfig.type then "--sandbox=type=\($c.sandboxConfig.type | ascii_downcase)" else empty end),
      (if $c.reservationAffinity.consumeReservationType then "--reservation-affinity=\($c.reservationAffinity.consumeReservationType | ascii_downcase | sub("_";"-";"g"))" else empty end),
      (if $c.bootDiskKmsKey then "--boot-disk-kms-key=\($c.bootDiskKmsKey)" else empty end),

      (if (.locations // []) | length > 0 then "--node-locations=" + (.locations | join(",")) else empty end),
      (if .maxPodsConstraint.maxPodsPerNode then "--max-pods-per-node=\(.maxPodsConstraint.maxPodsPerNode)" else empty end),

      (if $n.podRange then "--pod-ipv4-range=\($n.podRange)" else empty end),
      (if $n.enablePrivateNodes == true then "--enable-private-nodes" else empty end),

      (if $a.enabled == true then "--enable-autoscaling" else empty end),
      (if $a.enabled == true and $a.totalMinNodeCount then "--total-min-nodes=\($a.totalMinNodeCount)" else empty end),
      (if $a.enabled == true and $a.totalMaxNodeCount then "--total-max-nodes=\($a.totalMaxNodeCount)" else empty end),
      (if $a.enabled == true and $a.minNodeCount then "--min-nodes=\($a.minNodeCount)" else empty end),
      (if $a.enabled == true and $a.maxNodeCount then "--max-nodes=\($a.maxNodeCount)" else empty end),
      (if $a.enabled == true and $a.locationPolicy then "--location-policy=\($a.locationPolicy)" else empty end),
      (if $a.enabled != true then "--num-nodes=\(.initialNodeCount // 1)" else empty end),

      (if $m.autoRepair == true then "--enable-autorepair" else "--no-enable-autorepair" end),
      (if $m.autoUpgrade == true then "--enable-autoupgrade" else "--no-enable-autoupgrade" end),

      (.upgradeSettings // {}) as $u |
      (if $u.strategy == "BLUE_GREEN" then "--enable-blue-green-upgrade"
        elif $u.maxSurge != null then "--max-surge-upgrade=\($u.maxSurge)"
        else empty end),
      (if $u.strategy != "BLUE_GREEN" and $u.maxUnavailable != null then "--max-unavailable-upgrade=\($u.maxUnavailable)" else empty end)
    ] | .[]
  ' <<<"$json"
}
