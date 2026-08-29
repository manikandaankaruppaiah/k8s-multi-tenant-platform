# k8s-multi-tenant-platform — Design

## Purpose

A personal, from-scratch demonstration repo showing GitOps, multi-tenant
Kubernetes patterns, observability, and security hardening — built to be
shared publicly on GitHub and referenced from LinkedIn/resume. All content
is original and generic; no proprietary employer material, naming, or
configuration is reused.

## Success criteria

- Anyone can clone the repo and run `make up` to get a working local
  multi-tenant platform on `kind`, no cloud account required.
- The repo demonstrates, with real running components (not just YAML on
  disk): GitOps deployment via ArgoCD, per-tenant isolation, observability
  with custom dashboards/alerts, and policy-enforced security hardening.
- A CI pipeline runs on every push/PR and passes (lint + validate + smoke
  test), giving the repo a visible green badge.
- README explains the architecture and what each pillar demonstrates, in
  language suitable for a reviewer skimming it in two minutes.

## Non-goals

- No real cloud provisioning (EKS/Terraform) in the working demo — the
  README notes how it would extend to EKS, but nothing here requires cloud
  spend to run.
- No original application code — the workload is Google's existing
  `microservices-demo` ("Online Boutique"), used as-is via its published
  container images.
- Not a production-grade platform — depth is calibrated for a portfolio
  demo, not for operating real tenants.

## Architecture

**Cluster:** `kind`, single node config is fine; a Makefile target creates
it (`make up`) and tears it down (`make down`).

**Workload:** Google's `microservices-demo` (~11 services: frontend, cart,
checkout, payment, etc.), deployed via its upstream Helm chart, wrapped by
a thin local chart (`charts/boutique`) that layers on tenant-specific
values.

**GitOps:** ArgoCD installed via its standard install manifests
(`argocd/install/`). An `ApplicationSet` (`argocd/applicationset.yaml`)
uses a list generator over three fictional tenants — `tenant-acme`,
`tenant-globex`, `tenant-initech` — each deployed into its own namespace
using `values/tenants/<name>.yaml` for per-tenant differences (replica
counts, resource requests, a feature-flag-style env var). This is the
core "multi-tenant GitOps" demonstration: one ApplicationSet, N
independently-configured tenant deployments.

**Observability:** kube-prometheus-stack (Prometheus + Grafana) and Loki,
installed via their upstream Helm charts under `observability/`.
Two hand-built Grafana dashboards (JSON under
`observability/dashboards/`) covering per-tenant request rate/error
rate/latency (RED metrics) and pod resource usage. Two Prometheus alert
rules (`observability/alerts/`) — e.g. high error rate, pod
CrashLoopBackOff.

**Security:**
- NetworkPolicies per tenant namespace: default-deny ingress/egress, then
  explicit allows for intra-namespace traffic and to shared
  observability/ArgoCD namespaces.
- RBAC: a `tenant-viewer` Role + RoleBinding scoped to each tenant
  namespace, demonstrating least-privilege per-tenant access.
- Pod Security Standards: each tenant namespace labeled
  `pod-security.kubernetes.io/enforce: restricted`.
- ResourceQuota per tenant namespace.
- Kyverno installed as an admission controller enforcing cluster-wide
  policies (`security/kyverno-policies/`): require resource
  requests/limits on every container, disallow `:latest` image tags,
  require `runAsNonRoot`.

**CI:** GitHub Actions workflow (`.github/workflows/ci.yaml`) that on
every push/PR:
1. `helm lint` on `charts/boutique` and any local charts.
2. Manifest validation (`kubeconform`) on rendered templates and raw
   manifests (ArgoCD install, security policies).
3. Spins up a `kind` cluster, installs ArgoCD + the ApplicationSet,
   waits for sync health, and asserts each tenant namespace has running
   pods (smoke test script, `scripts/smoke-test.sh`).

## Repo layout

```
k8s-multi-tenant-platform/
├── README.md
├── Makefile
├── argocd/
│   ├── install/
│   └── applicationset.yaml
├── charts/
│   └── boutique/
├── values/
│   └── tenants/
│       ├── acme.yaml
│       ├── globex.yaml
│       └── initech.yaml
├── security/
│   ├── network-policies/
│   ├── rbac/
│   └── kyverno-policies/
├── observability/
│   ├── install/
│   ├── dashboards/
│   └── alerts/
├── scripts/
│   └── smoke-test.sh
└── .github/workflows/ci.yaml
```

## Testing

- `helm lint` and `kubeconform` run locally via `make lint` and in CI.
- `scripts/smoke-test.sh` waits for ArgoCD Application health/sync status
  per tenant and checks `kubectl get pods -n tenant-<x>` shows all pods
  Running — run both locally (`make demo`) and in CI.
- Manual verification: port-forward Grafana, confirm the two custom
  dashboards render data from real traffic (Online Boutique has a
  built-in load generator service to produce that traffic).

## Open questions / risks

- Resource footprint: microservices-demo + kube-prometheus-stack + Loki +
  Kyverno + 3x tenant replicas may be heavy for a laptop `kind` cluster.
  Mitigation: keep per-tenant replica counts low (1-2) and trim
  kube-prometheus-stack's default scrape targets if needed. If CI runners
  can't fit it, scope the CI smoke test to a subset (e.g. one tenant) and
  note in the README that the full local demo is best run manually.
