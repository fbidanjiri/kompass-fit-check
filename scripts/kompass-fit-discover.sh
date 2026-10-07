#!/usr/bin/env bash
# Kompass Fit Check — cluster discovery script.
# Read-only kubectl probes that answer as many fit-check questions as possible
# directly from cluster state, so the customer doesn't have to.
# Usage: ./kompass-fit-discover.sh [kubectl-context-name]
set -uo pipefail

CTX_ARGS=()
if [[ "${1:-}" != "" ]]; then
  CTX_ARGS=(--context "$1")
fi
K() { kubectl "${CTX_ARGS[@]}" "$@" 2>/dev/null; }

section() { printf '\n## %s\n' "$1"; }
kv() { printf '%-28s %s\n' "$1:" "$2"; }

echo "# Kompass Fit Check — cluster discovery dump"
echo "# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Cloud is inferred from the first node's providerID prefix (aws:///, azure://, oci://)
# so the script doesn't need a --cloud flag and works unmodified across EKS/AKS/OKE.
PROVIDER_ID=$(K get nodes -o jsonpath='{.items[0].spec.providerID}')
case "$PROVIDER_ID" in
  aws://*)   CLOUD="aws" ;;
  azure://*) CLOUD="azure" ;;
  oci://*)   CLOUD="oracle" ;;
  *)         CLOUD="unknown" ;;
esac
kv "cloud (detected from node providerID)" "$CLOUD"

# ---------- Platform and autoscaling ----------
section "kver (Kubernetes version)"
K version -o json | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get("serverVersion",{}).get("gitVersion","unknown"))
except Exception:
    print("could not determine")
'

section "autoscaler (Node autoscaler)"
if K get crd nodepools.karpenter.sh >/dev/null 2>&1 || K get crd nodepools.karpenter.azure.com >/dev/null 2>&1 || K get crd nodepools.karpenter.k8s.oracle.com >/dev/null 2>&1; then
  kv "detected" "Karpenter (nodepools CRD present)"
elif K get deploy -n kube-system cluster-autoscaler >/dev/null 2>&1; then
  kv "detected" "Cluster Autoscaler"
else
  case "$CLOUD" in
    aws)    kv "detected" "none found — confirm manually, may be managed-node-groups-only or EKS Auto Mode" ;;
    azure)  kv "detected" "none found — confirm manually, may be AKS's built-in cluster autoscaler add-on (check \`az aks show --query autoScalerProfile\`)" ;;
    oracle) kv "detected" "none found — confirm manually, may be OKE's node pool autoscaling" ;;
    *)      kv "detected" "none found — confirm manually" ;;
  esac
fi

section "hpa (HPA/KEDA coverage)"
HPA_COUNT=$(K get hpa -A --no-headers | wc -l | tr -d ' ')
KEDA_COUNT=$(K get scaledobjects.keda.sh -A --no-headers | wc -l | tr -d ' ')
WORKLOAD_COUNT=$(K get deploy,statefulset -A --no-headers | wc -l | tr -d ' ')
kv "HPA objects" "$HPA_COUNT"
kv "KEDA ScaledObjects" "$KEDA_COUNT"
kv "Deployments+StatefulSets" "$WORKLOAD_COUNT"
kv "note" "coverage ratio is (HPA+KEDA)/workloads — compute after reviewing for overlap"

section "vpaExisting (Existing VPA)"
if K get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null 2>&1; then
  VPA_COUNT=$(K get vpa -A --no-headers | wc -l | tr -d ' ')
  kv "VPA CRD present" "yes — $VPA_COUNT VerticalPodAutoscaler objects found"
else
  kv "VPA CRD present" "no"
fi

# ---------- Scale and workload mix ----------
section "nodes (Node count)"
kv "node count" "$(K get nodes --no-headers | wc -l | tr -d ' ')"

section "workloads (Workload count) and mix (kinds)"
kv "Deployments"  "$(K get deploy -A --no-headers | wc -l | tr -d ' ')"
kv "StatefulSets" "$(K get statefulset -A --no-headers | wc -l | tr -d ' ')"
kv "DaemonSets"   "$(K get daemonset -A --no-headers | wc -l | tr -d ' ')"
kv "CronJobs"     "$(K get cronjob -A --no-headers | wc -l | tr -d ' ')"
kv "Jobs"         "$(K get job -A --no-headers | wc -l | tr -d ' ')"

section "pdb (PodDisruptionBudget coverage)"
PDB_COUNT=$(K get pdb -A --no-headers | wc -l | tr -d ' ')
kv "PDB objects" "$PDB_COUNT"
kv "note" "compare against workload count above for coverage ratio"

section "javaWorkloads (Java/JVM workloads) — heuristic, verify manually"
JAVA_HITS=$(K get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | grep -Ei 'jdk|jre|openjdk|corretto|tomcat|spring|java' | sort -u | wc -l | tr -d ' ')
kv "container images matching java/jdk/tomcat/spring" "$JAVA_HITS"
kv "note" "false positives/negatives likely — treat as a prompt to ask, not a final answer"

# ---------- Networking and cluster policy ----------
section "cni (CNI plugin)"
FOUND_CNI=0
if K get ds -n kube-system aws-node >/dev/null 2>&1; then
  kv "detected" "AWS VPC CNI (aws-node daemonset present)"; FOUND_CNI=1
fi
if K get ds -n kube-system cilium >/dev/null 2>&1; then
  kv "detected" "Cilium (cilium daemonset present)"; FOUND_CNI=1
fi
if K get ds -n kube-system calico-node >/dev/null 2>&1; then
  kv "detected" "Calico (calico-node daemonset present)"; FOUND_CNI=1
fi
if K get ds -n kube-system canal >/dev/null 2>&1; then
  kv "detected" "Canal (canal daemonset present)"; FOUND_CNI=1
fi
if K get ds -n kube-system kube-flannel-ds >/dev/null 2>&1; then
  kv "detected" "Flannel (kube-flannel-ds daemonset present)"; FOUND_CNI=1
fi
# Azure CNI and OCI's VCN-Native CNI don't run as a visible kube-system daemonset —
# they're implemented via the node's own network config / the cloud's CCM, so absence
# of the daemonsets above is itself the (weak) signal on those two clouds.
if [[ "$FOUND_CNI" == "0" ]]; then
  case "$CLOUD" in
    aws)    kv "detected" "likely AWS VPC CNI (default) — no distinguishing daemonset found by name, confirm manually" ;;
    azure)  kv "detected" "likely Azure CNI (default) or Kubenet — Azure's default CNI doesn't run as its own kube-system daemonset, confirm manually" ;;
    oracle) kv "detected" "likely OCI VCN-Native CNI (default) — implemented via the OCI Cloud Controller Manager and per-node VNICs, not a daemonset, confirm manually" ;;
    *)      kv "detected" "could not determine — confirm manually" ;;
  esac
fi

section "ciliumMode (Cilium IPAM mode) — only relevant if Cilium detected above"
K get configmap -n kube-system cilium-config -o jsonpath='{.data.ipam}' 2>/dev/null | sed 's/^/ipam=/' || echo "cilium-config not found"

section "mesh (Service mesh)"
FOUND_MESH=0
if K get ns istio-system >/dev/null 2>&1; then
  kv "detected" "Istio (istio-system namespace present)"; FOUND_MESH=1
fi
if K get ns linkerd >/dev/null 2>&1; then
  kv "detected" "Linkerd (linkerd namespace present)"; FOUND_MESH=1
fi
INJECTED=$(K get pods -A -o jsonpath='{range .items[*]}{.metadata.annotations.sidecar\.istio\.io/status}{.metadata.annotations.linkerd\.io/inject}{"\n"}{end}' | grep -v '^$' | wc -l | tr -d ' ')
kv "pods with sidecar injection annotations" "$INJECTED"
[[ "$FOUND_MESH" == "0" && "$INJECTED" == "0" ]] && kv "detected" "none found — likely 'No mesh, or open egress'"

section "webhooks (Third-party mutating webhooks)"
K get mutatingwebhookconfigurations -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort -u

# ---------- Delivery and cost visibility ----------
section "gitops (GitOps tooling)"
FOUND_GITOPS=0
if K get crd applications.argoproj.io >/dev/null 2>&1; then
  kv "detected" "Argo CD (applications.argoproj.io CRD present)"; FOUND_GITOPS=1
fi
if K get crd kustomizations.kustomize.toolkit.fluxcd.io >/dev/null 2>&1; then
  kv "detected" "Flux (kustomizations.kustomize.toolkit.fluxcd.io CRD present)"; FOUND_GITOPS=1
fi
if K get crd bundles.fleet.cattle.io >/dev/null 2>&1; then
  kv "detected" "Rancher Fleet (bundles.fleet.cattle.io CRD present)"; FOUND_GITOPS=1
fi
[[ "$FOUND_GITOPS" == "0" ]] && kv "detected" "none (no Argo CD / Flux / Fleet CRDs found) — likely 'None' or a tool outside this list"

section "deployMethod (signal only — client-side tool, can't be fully determined in-cluster)"
HELM_RELEASES=$(K get secrets -A -l owner=helm --no-headers 2>/dev/null | wc -l | tr -d ' ')
kv "Helm release secrets found" "$HELM_RELEASES"
kv "note" "presence suggests Helm was used at some point; does not confirm CLI vs Terraform-provider vs GitOps-driven installs"

section "storage (storage class supports expansion)"
K get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{" allowVolumeExpansion="}{.allowVolumeExpansion}{"\n"}{end}'

section "cur (cost export availability) — cloud-account-level, NOT detectable from inside the cluster"
case "$CLOUD" in
  aws)    kv "note" "requires AWS Cost Explorer / CUR API access (\`aws ce ...\` or the CUR S3 export config), out of scope for a kubectl script" ;;
  azure)  kv "note" "requires the Azure Cost Management API / exports (\`az costmanagement export list\`), out of scope for a kubectl script" ;;
  oracle) kv "note" "requires the OCI Usage API / Usage Reports (\`oci usage-api ...\`), out of scope for a kubectl script" ;;
  *)      kv "note" "requires the relevant cloud's cost/billing API, out of scope for a kubectl script" ;;
esac

# ---------- Observability and monitoring ----------
section "observability (Existing observability stack)"
# Captured into variables (not piped live into `grep -q`) — with `pipefail` set,
# grep -q's early exit on first match can SIGPIPE the producing kubectl call
# and flip the pipeline's exit status, silently hiding real matches.
DD_AGENT=$(K get ds -A -l app=datadog-agent --no-headers)
ALL_DEPLOYS=$(K get deploy -A)
ALL_PODS=$(K get pods -A)
CW_AGENT=$(K get pods -A -l app.kubernetes.io/name=aws-cloudwatch-metrics --no-headers)
FOUND_OBS=0
[[ -n "$DD_AGENT" ]] && { kv "detected" "Datadog agent daemonset"; FOUND_OBS=1; }
grep -qi prometheus <<<"$ALL_DEPLOYS" && { kv "detected" "Prometheus (deployment name match)"; FOUND_OBS=1; }
grep -qi grafana <<<"$ALL_DEPLOYS" && { kv "detected" "Grafana (deployment name match)"; FOUND_OBS=1; }
grep -qi splunk <<<"$ALL_PODS" && { kv "detected" "Splunk forwarder (pod name match)"; FOUND_OBS=1; }
[[ -n "$CW_AGENT" ]] && { kv "detected" "CloudWatch Container Insights agent"; FOUND_OBS=1; }
[[ "$FOUND_OBS" == "0" ]] && kv "detected" "none of Datadog/Prometheus/Grafana/Splunk/CloudWatch found by name — confirm manually"

section "ksmExisting (Existing kube-state-metrics)"
KSM=$(K get deploy -A 2>/dev/null | grep -i kube-state-metrics)
if [[ -n "$KSM" ]]; then
  kv "detected" "yes"
  echo "$KSM"
else
  kv "detected" "no"
fi

section "auditLogging (control-plane audit logging) — cloud API, NOT detectable from inside the cluster"
case "$CLOUD" in
  aws)    kv "note" "requires \`aws eks describe-cluster --name <cluster> --query cluster.logging\`, run with cloud credentials" ;;
  azure)  kv "note" "requires \`az aks show --query addonProfiles\` or checking diagnostic settings for the kube-audit category, run with cloud credentials" ;;
  oracle) kv "note" "OCI Audit service is enabled tenancy-wide by default (not a per-cluster toggle) — confirm retention/forwarding via \`oci audit ...\` or the console, run with cloud credentials" ;;
  *)      kv "note" "requires the relevant cloud's control-plane logging API, run with cloud credentials" ;;
esac

echo
echo "# End of dump"
