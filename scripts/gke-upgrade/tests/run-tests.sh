#!/usr/bin/env bash
# Offline unit tests for the pure logic in lib.sh — no gcloud, no cluster.
# ok/no always succeed, so `cond && ok || no` is a real if-then-else.
# shellcheck disable=SC2015
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
source "${HERE}/../lib.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }

expect_eq() {
  local desc=$1 want=$2 got=$3
  [[ "$want" == "$got" ]] && ok "$desc" || no "$desc" "$want" "$got"
}

expect_rc() {
  local desc=$1 want=$2
  shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  [[ "$want" == "$got" ]] && ok "$desc" || no "$desc" "rc=$want" "rc=$got"
}

echo "gke_minor_num"
expect_eq "extracts minor from a gke version" "35" "$(gke_minor_num 1.35.6-gke.1258000)"
expect_eq "extracts minor from a bare semver" "36" "$(gke_minor_num 1.36.2)"

echo "gke_version_cmp"
expect_eq "equal versions"        "0"  "$(gke_version_cmp 1.35.6-gke.1258000 1.35.6-gke.1258000)"
expect_eq "patch newer"           "1"  "$(gke_version_cmp 1.35.7-gke.1027000 1.35.6-gke.1258000)"
expect_eq "patch older"           "-1" "$(gke_version_cmp 1.35.6-gke.1258000 1.35.7-gke.1027000)"
expect_eq "minor newer"           "1"  "$(gke_version_cmp 1.36.2-gke.2064000 1.35.6-gke.1258000)"
expect_eq "gke build newer"       "1"  "$(gke_version_cmp 1.35.6-gke.1258000 1.35.6-gke.1250000)"
expect_eq "gke build older"       "-1" "$(gke_version_cmp 1.35.6-gke.1250000 1.35.6-gke.1258000)"
expect_eq "build compares numerically not lexically" "1" "$(gke_version_cmp 1.35.6-gke.1258000 1.35.6-gke.999000)"

echo "assert_upgrade_path"
expect_rc "same version is a no-op, allowed"        0 assert_upgrade_path 1.35.6-gke.1258000 1.35.6-gke.1258000
expect_rc "patch bump allowed"                      0 assert_upgrade_path 1.35.6-gke.1250000 1.35.6-gke.1258000
expect_rc "single minor bump allowed"               0 assert_upgrade_path 1.35.6-gke.1258000 1.36.2-gke.2064000
expect_rc "downgrade rejected"                      1 assert_upgrade_path 1.36.2-gke.2064000 1.35.6-gke.1258000
expect_rc "two-minor skip rejected"                 1 assert_upgrade_path 1.34.9-gke.1322000 1.36.2-gke.2064000
expect_rc "major bump rejected"                     1 assert_upgrade_path 1.35.6-gke.1258000 2.0.0-gke.1000000
expect_rc "garbage version rejected"                1 assert_upgrade_path 1.35.6-gke.1258000 "latest"

echo "assert_node_not_ahead_of_control_plane"
expect_rc "node equal to control plane allowed"   0 assert_node_not_ahead_of_control_plane 1.35.6-gke.1258000 1.35.6-gke.1258000
expect_rc "node behind control plane allowed"     0 assert_node_not_ahead_of_control_plane 1.35.6-gke.1250000 1.35.6-gke.1258000
expect_rc "node ahead of control plane rejected"  1 assert_node_not_ahead_of_control_plane 1.36.2-gke.2064000 1.35.6-gke.1258000

echo "pool_create_flags — reproduces the live gpu-l4-spot spec"
GPU_POOL_JSON='{
  "autoscaling":{"enabled":true,"locationPolicy":"ANY","totalMaxNodeCount":1},
  "config":{
    "accelerators":[{"acceleratorCount":"1","acceleratorType":"nvidia-l4","gpuDriverInstallationConfig":{"gpuDriverVersion":"DEFAULT"}}],
    "bootDisk":{"diskType":"pd-ssd","sizeGb":"100"},
    "diskSizeGb":100,"diskType":"pd-ssd","effectiveCgroupMode":"EFFECTIVE_CGROUP_MODE_V2",
    "imageType":"COS_CONTAINERD",
    "kubeletConfig":{"insecureKubeletReadonlyPortEnabled":false,"maxParallelImagePulls":3},
    "labels":{"gpu":"l4","workload":"ai-inference"},
    "machineType":"g2-standard-4",
    "metadata":{"disable-legacy-endpoints":"true"},
    "resourceLabels":{"goog-gke-accelerator-type":"nvidia-l4","goog-gke-node-pool-provisioning-model":"spot"},
    "nodeImageConfig":{"image":"gke-1356-gke1258000-cos-125-19216-395-138-c-nvda","imageProject":"gke-node-images"},
    "serviceAccount":"default","spot":true,"windowsNodeConfig":{},
    "workloadMetadataConfig":{"mode":"GKE_METADATA"}
  },
  "etag":"e653563b","instanceGroupUrls":["https://example/grp"],
  "locations":["asia-south1-b"],
  "management":{"autoRepair":true,"autoUpgrade":true},
  "maxPodsConstraint":{"maxPodsPerNode":"110"},
  "name":"gpu-l4-spot",
  "networkConfig":{"enablePrivateNodes":true,"networkTierConfig":{"networkTier":"NETWORK_TIER_DEFAULT"},"podIpv4CidrBlock":"10.20.0.0/16","podRange":"pods","subnetwork":"projects/p/regions/r/subnetworks/s"},
  "podIpv4CidrSize":24,"selfLink":"https://example","status":"RUNNING",
  "upgradeSettings":{"maxSurge":1,"strategy":"SURGE"},
  "version":"1.35.6-gke.1258000"
}'

FLAGS="$(pool_create_flags "$GPU_POOL_JSON")"
rc=$?
expect_eq "flag generation succeeds" "0" "$rc"

has_flag() { grep -qF -- "$1" <<<"$FLAGS" && echo yes || echo no; }
expect_eq "machine type"        "yes" "$(has_flag "--machine-type=g2-standard-4")"
expect_eq "spot"                "yes" "$(has_flag "--spot")"
expect_eq "accelerator"         "yes" "$(has_flag "--accelerator=type=nvidia-l4,count=1,gpu-driver-version=default")"
expect_eq "disk type"           "yes" "$(has_flag "--disk-type=pd-ssd")"
expect_eq "disk size"           "yes" "$(has_flag "--disk-size=100")"
expect_eq "image type"          "yes" "$(has_flag "--image-type=COS_CONTAINERD")"
expect_eq "node labels"         "yes" "$(has_flag "--node-labels=gpu=l4,workload=ai-inference")"
expect_eq "node locations"      "yes" "$(has_flag "--node-locations=asia-south1-b")"
expect_eq "workload metadata"   "yes" "$(has_flag "--workload-metadata=GKE_METADATA")"
expect_eq "max pods per node"   "yes" "$(has_flag "--max-pods-per-node=110")"
expect_eq "pod range"           "yes" "$(has_flag "--pod-ipv4-range=pods")"
expect_eq "private nodes"       "yes" "$(has_flag "--enable-private-nodes")"
expect_eq "autoscaling enabled" "yes" "$(has_flag "--enable-autoscaling")"
expect_eq "autoscaling max"     "yes" "$(has_flag "--total-max-nodes=1")"
expect_eq "location policy"     "yes" "$(has_flag "--location-policy=ANY")"
expect_eq "autorepair"          "yes" "$(has_flag "--enable-autorepair")"
expect_eq "autoupgrade"         "yes" "$(has_flag "--enable-autoupgrade")"
expect_eq "service account"     "no"  "$(has_flag "--service-account")"
expect_eq "surge settings"      "yes" "$(has_flag "--max-surge-upgrade=1")"
expect_eq "no bare --num-nodes with autoscaling" "no" "$(has_flag "--num-nodes")"
expect_eq "server-derived node image is ignored, not reproduced" "no" "$(has_flag "gke-1356")"

echo "pool_create_flags — fails closed on specs it cannot reproduce"
TAINTED_POOL_JSON='{"name":"p","config":{"machineType":"e2-small","taints":[{"key":"k","value":"v","effect":"NO_SCHEDULE"}]},"locations":["asia-south1-a"],"management":{}}'
expect_rc "taints are reproduced, not rejected" 0 pool_create_flags "$TAINTED_POOL_JSON"
expect_eq "taint flag emitted" "yes" \
  "$(pool_create_flags "$TAINTED_POOL_JSON" | grep -qF -- "--node-taints=k=v:NoSchedule" && echo yes || echo no)"

UNKNOWN_POOL_JSON='{"name":"p","config":{"machineType":"e2-small","someFutureGkeField":{"enabled":true}},"locations":["asia-south1-a"],"management":{}}'
expect_rc "unknown config field is rejected" 1 pool_create_flags "$UNKNOWN_POOL_JSON"

SANDBOX_POOL_JSON='{"name":"p","config":{"machineType":"e2-small","sandboxConfig":{"type":"GVISOR"}},"locations":["asia-south1-a"],"management":{}}'
expect_eq "gvisor sandbox flag emitted" "yes" \
  "$(pool_create_flags "$SANDBOX_POOL_JSON" | grep -qF -- "--sandbox=type=gvisor" && echo yes || echo no)"

echo "node_status_class — autoscaler churn must not block an upgrade"
expect_eq "ready node is fine"                     "ok"    "$(node_status_class "Ready")"
expect_eq "notready node blocks"                   "block" "$(node_status_class "NotReady")"
expect_eq "unknown node blocks"                    "block" "$(node_status_class "Unknown")"
expect_eq "cordoned-but-ready node only warns"     "warn"  "$(node_status_class "Ready,SchedulingDisabled")"
expect_eq "cordoned and notready still blocks"     "block" "$(node_status_class "NotReady,SchedulingDisabled")"

echo "unhealthy_delta — only newly-broken workloads fail the run"
BEFORE=$'observability/otel-gateway\nobservability/obs-api'
AFTER=$'observability/otel-gateway\nobservability/obs-api'
expect_eq "no new breakage" "" "$(unhealthy_delta "$BEFORE" "$AFTER")"

AFTER_WORSE=$'observability/otel-gateway\nobservability/obs-api\nhomechef/homechef-api'
expect_eq "new breakage surfaces" "homechef/homechef-api" "$(unhealthy_delta "$BEFORE" "$AFTER_WORSE")"

AFTER_BETTER=$'observability/otel-gateway'
expect_eq "recovery is not a failure" "" "$(unhealthy_delta "$BEFORE" "$AFTER_BETTER")"

echo
printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
