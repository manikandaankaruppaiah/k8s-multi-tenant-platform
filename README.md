# k8s-multi-tenant-platform

A local, reproducible demo of a multi-tenant Kubernetes platform: GitOps
deployment, per-tenant isolation, observability, and policy-enforced
security, built to run on a laptop via `kind` with no cloud account
required.

## What this demonstrates

- **GitOps multi-tenancy:** a single ArgoCD `ApplicationSet` deploys the
  same Helm chart into three independent tenant namespaces
  (`tenant-acme`, `tenant-globex`, `tenant-initech`), each with its own
  values file under `values/tenants/`.
- **Security hardening:** per-tenant default-deny NetworkPolicies (with an
  allow-list), per-tenant RBAC (`tenant-viewer` Role/RoleBinding), Pod
  Security Standards (`restricted` enforced on tenant namespaces), per-tenant
  ResourceQuotas, and three Kyverno ClusterPolicies: `require-resources`,
  `disallow-latest-tag` and `require-run-as-nonroot`.
- **Observability:** kube-prometheus-stack (Prometheus + Grafana) and Loki,
  with two hand-built Grafana dashboards ("Tenant RED Metrics" and "Pod
  Resource Usage") and two Prometheus alert rules
  (`TenantPodCrashLooping`, `TenantHighMemoryUsage`).
- **CI:** every push to `main` and every pull request lints the Helm chart
  (`make lint`), validates rendered and raw manifests with `kubeconform`,
  and runs a smoke test on a real `kind` cluster. Standard GitHub-hosted
  runners cannot fit all three tenants, so the CI smoke test deploys the
  `acme` tenant only. The full three-tenant flow is verified locally with
  `make smoke-test`.

The workload is Google's open-source
[microservices-demo](https://github.com/GoogleCloudPlatform/microservices-demo)
("Online Boutique"); the platform wiring around it (multi-tenant GitOps,
hardening, observability) is original.

## Prerequisites

- Docker, [`kind`](https://kind.sigs.k8s.io/), `kubectl` and `helm`.
- Resources: each tenant runs the full 11-service boutique stack, so three
  tenants plus ArgoCD, Kyverno and the observability stack is heavy. Budget
  roughly 4+ CPUs and 8+ GB of memory for Docker (the tenant quotas alone
  allow 4 CPU / 4Gi of requests per tenant, and measured usage is about
  1.6 CPU / 1.7Gi of requests per tenant). First convergence also pulls many
  images and can take a long while (up to an hour on a slow link).
- The boutique images are amd64-only. On Apple Silicon they run under
  emulation, which is noticeably slower, and slow-starting services can
  restart a few times before they settle.

## Quickstart

ArgoCD syncs the application from GitHub, not from your local files.
`argocd/applicationset.yaml` points at
`https://github.com/manikandaankaruppaiah/k8s-multi-tenant-platform.git`
(`spec.template.spec.source.repoURL`) on branch `main`
(`targetRevision`). If you fork this repo, change `repoURL` (and
`targetRevision` if you use another branch), and push, before running
`make deploy`. Changes you have not pushed will not be deployed.

```bash
make up            # create local kind cluster
make argocd        # install ArgoCD
make security      # namespaces, quotas, network policies, RBAC
make kyverno       # cluster-wide policy enforcement
make deploy        # ApplicationSet deploys the app to 3 tenants
make observability # Prometheus, Grafana, Loki, dashboards, alerts
make smoke-test    # verify everything is healthy
```

Or run it all at once (this waits 90 seconds for ArgoCD to sync before the
smoke test; on a slow machine the smoke test may need to be re-run once the
pods have settled):

```bash
make demo
```

Grafana: `kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80`,
then visit `http://localhost:3000` (`admin` / `admin`, set in
`observability/install/kube-prometheus-stack-values.yaml`).

Tear down: `make down`

Other targets: `make lint` (Helm lint for each tenant) and
`make dashboards` (re-apply the dashboards and alert rules).

## Architecture

```
kind cluster
├── argocd (namespace)
│   └── ApplicationSet → 3x Application (boutique-acme/globex/initech)
├── tenant-acme / tenant-globex / tenant-initech (namespaces)
│   ├── Online Boutique services (per-tenant values)
│   ├── NetworkPolicy (default-deny + allow-list)
│   ├── RBAC (tenant-viewer Role/RoleBinding)
│   └── ResourceQuota
├── kyverno (namespace) — cluster-wide admission policies
└── observability (namespace)
    ├── Prometheus + Grafana (kube-prometheus-stack)
    ├── Loki
    └── custom dashboards + alert rules
```

## Extending to real cloud

This repo is intentionally local-only. To run it on real infrastructure,
the natural next step is to provision an EKS (or GKE/AKS) cluster with
Terraform and point the ApplicationSet's `destination.server` at it. A few
settings are tuned for a local kind cluster and should be revisited:

- The frontend Service type defaults to `ClusterIP`
  (`frontend.externalServiceType` in `charts/boutique/values.yaml`) because
  kind has no cloud load balancer controller. Override it per environment
  (for example `LoadBalancer`) or add an Ingress.
- Loki runs as a single binary on filesystem storage
  (`observability/install/loki-values.yaml`); use object storage in
  production.
- Grafana uses a fixed `admin` password, and the tenant ResourceQuotas are
  sized for this demo.

## Repo layout

See `docs/superpowers/specs/2026-08-29-k8s-multi-tenant-platform-design.md`
for the full design rationale.
