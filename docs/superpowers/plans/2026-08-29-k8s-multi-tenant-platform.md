# k8s-multi-tenant-platform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local, reproducible multi-tenant Kubernetes demo platform (GitOps + observability + security) suitable for a public GitHub portfolio repo.

**Architecture:** A `kind` cluster runs ArgoCD, which uses an `ApplicationSet` to deploy Google's `microservices-demo` Helm chart into three tenant namespaces with per-tenant values. Each tenant namespace is hardened with NetworkPolicies, RBAC, Pod Security Standards, and ResourceQuotas; Kyverno enforces cluster-wide policies on top. kube-prometheus-stack and Loki provide observability with two custom Grafana dashboards and two alert rules. GitHub Actions runs lint/validate/smoke-test on every push.

**Tech Stack:** kind, Helm 3, ArgoCD, Kyverno, kube-prometheus-stack, Loki, GitHub Actions, bash, `kubeconform`.

**Spec:** `docs/superpowers/specs/2026-08-29-k8s-multi-tenant-platform-design.md`

## Global Constraints

- No proprietary/employer content anywhere in this repo — all names, values, and policies are original or from upstream open-source projects (spec: Purpose).
- No cloud provisioning required to run the demo — everything targets `kind` (spec: Non-goals).
- Application workload is Google's `microservices-demo`, used via its upstream Helm chart, not custom app code (spec: Non-goals).
- Tenant namespaces: `tenant-acme`, `tenant-globex`, `tenant-initech` (spec: Architecture > GitOps).
- Keep per-tenant replica counts low (1-2) to fit a laptop `kind` cluster (spec: Open questions/risks).
- CI's smoke test may be scoped to the GitOps/tenant deployment subset rather than the full stack, per the spec's resource-footprint mitigation (spec: Open questions/risks).

---

## File Structure

```
k8s-multi-tenant-platform/
├── README.md
├── Makefile
├── .gitignore
├── kind-config.yaml
├── argocd/
│   ├── install/kustomization.yaml       # pulls upstream ArgoCD install manifest
│   └── applicationset.yaml
├── charts/
│   └── boutique/
│       ├── Chart.yaml                    # thin wrapper, depends on upstream chart
│       └── values.yaml                   # shared defaults
├── values/
│   └── tenants/
│       ├── acme.yaml
│       ├── globex.yaml
│       └── initech.yaml
├── security/
│   ├── namespaces/
│   │   ├── tenant-acme.yaml
│   │   ├── tenant-globex.yaml
│   │   └── tenant-initech.yaml
│   ├── network-policies/tenant-policy.yaml   # templated per tenant via kustomize vars, or 3 explicit files
│   ├── rbac/tenant-viewer.yaml
│   └── kyverno-policies/
│       ├── require-resources.yaml
│       ├── disallow-latest-tag.yaml
│       └── require-run-as-nonroot.yaml
├── observability/
│   ├── install/
│   │   ├── kube-prometheus-stack-values.yaml
│   │   └── loki-values.yaml
│   ├── dashboards/
│   │   ├── tenant-red-metrics.json
│   │   └── pod-resource-usage.json
│   └── alerts/boutique-alerts.yaml
├── scripts/
│   └── smoke-test.sh
└── .github/workflows/ci.yaml
```

**Responsibilities:**
- `Makefile` — single entrypoint (`up`, `down`, `argocd`, `deploy`, `security`, `observability`, `demo`, `lint`, `smoke-test`) so a reviewer never needs to memorize commands.
- `security/namespaces/*.yaml` — one file per tenant, each declaring the Namespace with Pod Security Standard labels and its ResourceQuota (kept together since they change together).
- `security/network-policies/` and `rbac/` — generic templates applied to all three tenant namespaces (namespace name is the only variable, applied via a loop in the Makefile, not three near-duplicate files).
- `values/tenants/*.yaml` — the actual per-tenant Helm values diffs (replica count, a feature-flag env var, resource requests).

---

## Task 1: Repo scaffolding and kind cluster

**Files:**
- Create: `.gitignore`
- Create: `kind-config.yaml`
- Create: `Makefile`
- Test: manual (`make up` / `make down`)

**Interfaces:**
- Produces: `make up` (creates kind cluster named `k8s-multi-tenant-platform`), `make down` (deletes it). All later tasks add Makefile targets to this same file.

- [ ] **Step 1: Create `.gitignore`**

```
.DS_Store
*.tmp
kubeconfig
```

- [ ] **Step 2: Create `kind-config.yaml`**

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: k8s-multi-tenant-platform
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 8080
        protocol: TCP
```

- [ ] **Step 3: Create `Makefile` with cluster lifecycle targets**

```makefile
CLUSTER_NAME := k8s-multi-tenant-platform

.PHONY: up down

up:
	kind create cluster --name $(CLUSTER_NAME) --config kind-config.yaml
	kubectl cluster-info --context kind-$(CLUSTER_NAME)

down:
	kind delete cluster --name $(CLUSTER_NAME)
```

- [ ] **Step 4: Verify cluster comes up**

Run: `make up`
Expected: kind cluster creates successfully, `kubectl cluster-info` prints the control-plane URL.

- [ ] **Step 5: Verify teardown**

Run: `make down`
Expected: cluster deleted with no errors.

- [ ] **Step 6: Commit**

```bash
git add .gitignore kind-config.yaml Makefile
git commit -m "Add kind cluster scaffolding"
```

---

## Task 2: Install ArgoCD

**Files:**
- Create: `argocd/install/kustomization.yaml`
- Modify: `Makefile` (append `argocd` target)
- Test: manual (`make up argocd`)

**Interfaces:**
- Consumes: running kind cluster from Task 1.
- Produces: `make argocd` target; ArgoCD running in namespace `argocd`, used by Task 4's ApplicationSet.

- [ ] **Step 1: Create `argocd/install/kustomization.yaml` pinning the upstream manifest**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: argocd
resources:
  - https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
```

- [ ] **Step 2: Add `argocd` Makefile target**

```makefile
.PHONY: argocd

argocd:
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -k argocd/install
	kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-server
```

- [ ] **Step 3: Verify ArgoCD comes up**

Run: `make up && make argocd`
Expected: `deployment.apps/argocd-server condition met`; `kubectl -n argocd get pods` shows all pods `Running`.

- [ ] **Step 4: Commit**

```bash
git add argocd/install/kustomization.yaml Makefile
git commit -m "Install ArgoCD via kustomize"
```

---

## Task 3: Boutique chart wrapper and tenant values

**Files:**
- Create: `charts/boutique/Chart.yaml`
- Create: `charts/boutique/values.yaml`
- Create: `values/tenants/acme.yaml`
- Create: `values/tenants/globex.yaml`
- Create: `values/tenants/initech.yaml`
- Test: `helm template` for each tenant values file

**Interfaces:**
- Produces: `charts/boutique` Helm chart (wraps upstream `oci://us-docker.pkg.dev/online-boutique-ci/charts/onlineboutique`), consumed by Task 4's ApplicationSet via `chart: charts/boutique` + tenant `values/tenants/<name>.yaml`.
- Values contract each tenant file must set: `replicaCount` (int), `tenantName` (string, injected as env var `TENANT_NAME` on frontend), `frontend.resources.requests.cpu`/`memory`.

- [ ] **Step 1: Create `charts/boutique/Chart.yaml`**

```yaml
apiVersion: v2
name: boutique
description: Thin wrapper around Google's Online Boutique microservices-demo for per-tenant deployment
version: 0.1.0
dependencies:
  - name: onlineboutique
    version: "0.10.1"
    repository: "oci://us-docker.pkg.dev/online-boutique-ci/charts"
```

- [ ] **Step 2: Create `charts/boutique/values.yaml` with shared defaults**

```yaml
onlineboutique:
  frontend:
    replicas: 1
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
  loadGenerator:
    create: true
```

- [ ] **Step 3: Create `values/tenants/acme.yaml`**

```yaml
onlineboutique:
  frontend:
    replicas: 2
    env:
      - name: TENANT_NAME
        value: acme
    resources:
      requests:
        cpu: 75m
        memory: 96Mi
```

- [ ] **Step 4: Create `values/tenants/globex.yaml`**

```yaml
onlineboutique:
  frontend:
    replicas: 1
    env:
      - name: TENANT_NAME
        value: globex
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
```

- [ ] **Step 5: Create `values/tenants/initech.yaml`**

```yaml
onlineboutique:
  frontend:
    replicas: 1
    env:
      - name: TENANT_NAME
        value: initech
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
    loadGenerator:
      create: false
```

- [ ] **Step 6: Run `helm dependency update` and verify each tenant renders**

Run:
```bash
helm dependency update charts/boutique
helm template acme charts/boutique -f values/tenants/acme.yaml
helm template globex charts/boutique -f values/tenants/globex.yaml
helm template initech charts/boutique -f values/tenants/initech.yaml
```
Expected: each command prints valid Kubernetes manifests with no errors, and `grep TENANT_NAME` on the acme output shows `value: acme`.

- [ ] **Step 7: Commit**

```bash
git add charts/boutique values/tenants
git commit -m "Add boutique chart wrapper and per-tenant values"
```

---

## Task 4: ArgoCD ApplicationSet for multi-tenant deploy

**Files:**
- Create: `argocd/applicationset.yaml`
- Modify: `Makefile` (append `deploy` target)
- Test: manual, ArgoCD CLI/kubectl checks

**Interfaces:**
- Consumes: `charts/boutique` and `values/tenants/*.yaml` from Task 3; ArgoCD from Task 2.
- Produces: three ArgoCD `Application` resources (`boutique-acme`, `boutique-globex`, `boutique-initech`), each targeting namespace `tenant-<name>`. Task 9's smoke test checks these by name.

- [ ] **Step 1: Create `argocd/applicationset.yaml`**

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: boutique-tenants
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - tenant: acme
          - tenant: globex
          - tenant: initech
  template:
    metadata:
      name: "boutique-{{tenant}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/YOUR_GITHUB_USERNAME/k8s-multi-tenant-platform.git
        targetRevision: main
        path: charts/boutique
        helm:
          valueFiles:
            - "../../values/tenants/{{tenant}}.yaml"
      destination:
        server: https://kubernetes.default.svc
        namespace: "tenant-{{tenant}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

- [ ] **Step 2: Add `deploy` Makefile target**

```makefile
.PHONY: deploy

deploy:
	kubectl apply -f argocd/applicationset.yaml
```

- [ ] **Step 3: Verify sync (requires repo pushed to GitHub first — see Task 12 note)**

Run: `make deploy`, then `kubectl -n argocd get applications`
Expected: `boutique-acme`, `boutique-globex`, `boutique-initech` appear, eventually reaching `Synced`/`Healthy`. `kubectl get pods -n tenant-acme` shows Online Boutique pods Running.

(If iterating locally before the repo has a real GitHub remote, temporarily point `repoURL`/`targetRevision` at a local path or a `file://` remote to validate the ApplicationSet mechanics; revert to the real GitHub URL before the final commit in Task 12.)

- [ ] **Step 4: Commit**

```bash
git add argocd/applicationset.yaml Makefile
git commit -m "Add ApplicationSet for multi-tenant boutique deployment"
```

---

## Task 5: Tenant namespace hardening (PSS, quotas, network policy, RBAC)

**Files:**
- Create: `security/namespaces/tenant-acme.yaml`
- Create: `security/namespaces/tenant-globex.yaml`
- Create: `security/namespaces/tenant-initech.yaml`
- Create: `security/network-policies/tenant-policy.yaml`
- Create: `security/rbac/tenant-viewer.yaml`
- Modify: `Makefile` (append `security` target)
- Test: manual kubectl checks

**Interfaces:**
- Consumes: tenant namespace names (`tenant-acme`, `tenant-globex`, `tenant-initech`).
- Produces: namespaces exist with PSS `restricted` label and ResourceQuota before Task 4's `CreateNamespace=true` would otherwise create them bare; NetworkPolicy and RBAC objects labeled `tenant: <name>` for the smoke test / reviewer to inspect.

- [ ] **Step 1: Create `security/namespaces/tenant-acme.yaml`**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-acme
  labels:
    pod-security.kubernetes.io/enforce: restricted
    tenant: acme
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: tenant-quota
  namespace: tenant-acme
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "2"
    limits.memory: 2Gi
    pods: "20"
```

- [ ] **Step 2: Create `security/namespaces/tenant-globex.yaml` and `tenant-initech.yaml`** (identical structure, `globex`/`initech` substituted for `acme` in both `metadata.name` fields and the `tenant` label)

- [ ] **Step 3: Create `security/network-policies/tenant-policy.yaml` — one default-deny + allow-list NetworkPolicy per tenant, as three documents in one file**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-and-allow
  namespace: tenant-acme
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: {}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: argocd
  egress:
    - to:
        - podSelector: {}
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-and-allow
  namespace: tenant-globex
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: {}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: argocd
  egress:
    - to:
        - podSelector: {}
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-and-allow
  namespace: tenant-initech
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector: {}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: argocd
  egress:
    - to:
        - podSelector: {}
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

- [ ] **Step 4: Create `security/rbac/tenant-viewer.yaml` — one Role/RoleBinding pair per tenant, as three documents**

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-viewer
  namespace: tenant-acme
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-viewer
  namespace: tenant-acme
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-viewer
  namespace: tenant-acme
subjects:
  - kind: ServiceAccount
    name: tenant-viewer
    namespace: tenant-acme
roleRef:
  kind: Role
  name: tenant-viewer
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-viewer
  namespace: tenant-globex
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-viewer
  namespace: tenant-globex
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-viewer
  namespace: tenant-globex
subjects:
  - kind: ServiceAccount
    name: tenant-viewer
    namespace: tenant-globex
roleRef:
  kind: Role
  name: tenant-viewer
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-viewer
  namespace: tenant-initech
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps"]
    verbs: ["get", "list", "watch"]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-viewer
  namespace: tenant-initech
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-viewer
  namespace: tenant-initech
subjects:
  - kind: ServiceAccount
    name: tenant-viewer
    namespace: tenant-initech
roleRef:
  kind: Role
  name: tenant-viewer
  apiGroup: rbac.authorization.k8s.io
```

- [ ] **Step 5: Add `security` Makefile target (namespaces before RBAC/netpol so they exist first)**

```makefile
.PHONY: security

security:
	kubectl apply -f security/namespaces/
	kubectl apply -f security/network-policies/
	kubectl apply -f security/rbac/
```

- [ ] **Step 6: Verify**

Run: `make up && make security`
Expected: `kubectl get ns tenant-acme -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'` prints `restricted`; `kubectl get resourcequota -n tenant-acme` shows `tenant-quota`; `kubectl get networkpolicy -n tenant-acme` shows `default-deny-and-allow`; `kubectl get role,rolebinding -n tenant-acme` shows `tenant-viewer`.

- [ ] **Step 7: Commit**

```bash
git add security/namespaces security/network-policies security/rbac Makefile
git commit -m "Add per-tenant namespace hardening: PSS, quotas, network policy, RBAC"
```

---

## Task 6: Kyverno cluster-wide policies

**Files:**
- Create: `security/kyverno-policies/require-resources.yaml`
- Create: `security/kyverno-policies/disallow-latest-tag.yaml`
- Create: `security/kyverno-policies/require-run-as-nonroot.yaml`
- Modify: `Makefile` (append `kyverno` target)
- Test: manual — apply a violating Pod and confirm it's blocked

**Interfaces:**
- Consumes: running kind cluster.
- Produces: `make kyverno` target; three `ClusterPolicy` objects enforced cluster-wide, verified before Task 4's tenant apps are deployed against them.

- [ ] **Step 1: Create `security/kyverno-policies/require-resources.yaml`**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-requests-and-limits
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Every container must set resource requests and limits."
        pattern:
          spec:
            containers:
              - resources:
                  requests:
                    cpu: "?*"
                    memory: "?*"
                  limits:
                    cpu: "?*"
                    memory: "?*"
```

- [ ] **Step 2: Create `security/kyverno-policies/disallow-latest-tag.yaml`**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Images must not use the ':latest' tag; pin an explicit version."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

- [ ] **Step 3: Create `security/kyverno-policies/require-run-as-nonroot.yaml`**

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-nonroot
spec:
  validationFailureAction: Enforce
  background: true
  rules:
    - name: require-run-as-nonroot
      match:
        any:
          - resources:
              kinds: [Pod]
      validate:
        message: "Containers must set securityContext.runAsNonRoot: true."
        pattern:
          spec:
            =(securityContext):
              runAsNonRoot: true
            containers:
              - =(securityContext):
                  runAsNonRoot: true
```

- [ ] **Step 4: Add `kyverno` Makefile target (installs Kyverno itself, then the policies)**

```makefile
.PHONY: kyverno

kyverno:
	helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
	helm repo update
	helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
	kubectl apply -f security/kyverno-policies/
```

- [ ] **Step 5: Verify enforcement**

Run:
```bash
make up && make kyverno
kubectl run bad-pod --image=nginx:latest --restart=Never
```
Expected: the `kubectl run` command is rejected with a Kyverno admission error mentioning `disallow-latest-tag` (and/or the other two policies, since `nginx:latest` also lacks resources/runAsNonRoot).

- [ ] **Step 6: Commit**

```bash
git add security/kyverno-policies Makefile
git commit -m "Add Kyverno and cluster-wide policy enforcement"
```

---

## Task 7: Observability stack (Prometheus, Grafana, Loki)

**Files:**
- Create: `observability/install/kube-prometheus-stack-values.yaml`
- Create: `observability/install/loki-values.yaml`
- Modify: `Makefile` (append `observability` target)
- Test: manual — pods Running, port-forward reachable

**Interfaces:**
- Consumes: running kind cluster.
- Produces: `make observability` target; Prometheus/Grafana/Loki running in namespace `observability`, consumed by Task 8's dashboards/alerts.

- [ ] **Step 1: Create `observability/install/kube-prometheus-stack-values.yaml`**

```yaml
grafana:
  adminPassword: admin
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
prometheus:
  prometheusSpec:
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
    ruleSelectorNilUsesHelmValues: false
```

- [ ] **Step 2: Create `observability/install/loki-values.yaml`**

```yaml
loki:
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
singleBinary:
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
```

- [ ] **Step 3: Add `observability` Makefile target**

```makefile
.PHONY: observability

observability:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo add grafana https://grafana.github.io/helm-charts --force-update
	helm repo update
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		-n observability --create-namespace -f observability/install/kube-prometheus-stack-values.yaml --wait
	helm upgrade --install loki grafana/loki \
		-n observability -f observability/install/loki-values.yaml --wait
```

- [ ] **Step 4: Verify**

Run: `make up && make observability`
Expected: `kubectl get pods -n observability` shows Prometheus, Grafana, and Loki pods `Running`.

Run: `kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80` then open `http://localhost:3000` (login `admin`/`admin`)
Expected: Grafana UI loads.

- [ ] **Step 5: Commit**

```bash
git add observability/install Makefile
git commit -m "Add kube-prometheus-stack and Loki observability install"
```

---

## Task 8: Custom Grafana dashboards and Prometheus alerts

**Files:**
- Create: `observability/dashboards/tenant-red-metrics.json`
- Create: `observability/dashboards/pod-resource-usage.json`
- Create: `observability/alerts/boutique-alerts.yaml`
- Modify: `Makefile` (append dashboard/alert apply to `observability` target)
- Test: manual — ConfigMap/PrometheusRule created, dashboards visible in Grafana

**Interfaces:**
- Consumes: `observability` namespace from Task 7 (sidecar dashboard-loading enabled there).
- Produces: two dashboards auto-loaded into Grafana via the `grafana_dashboard: "1"` label; a `PrometheusRule` with two alert rules, consumed by Task 9's smoke test.

- [ ] **Step 1: Create `observability/dashboards/tenant-red-metrics.json`** — a minimal but real Grafana dashboard (Rate/Errors/Duration for the frontend service, using its `/metrics` if instrumented, else `kube_pod_status_phase` fallback since Online Boutique doesn't natively export request-rate metrics — use container CPU/network as the RED proxy)

```json
{
  "title": "Tenant RED Metrics",
  "uid": "tenant-red-metrics",
  "tags": ["tenant", "red"],
  "panels": [
    {
      "type": "timeseries",
      "title": "Frontend request rate (network receive bytes, per tenant)",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        {
          "expr": "sum by (namespace) (rate(container_network_receive_bytes_total{namespace=~\"tenant-.*\", pod=~\"frontend.*\"}[5m]))"
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Frontend container restarts (error proxy, per tenant)",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "targets": [
        {
          "expr": "sum by (namespace) (increase(kube_pod_container_status_restarts_total{namespace=~\"tenant-.*\", pod=~\"frontend.*\"}[15m]))"
        }
      ]
    }
  ]
}
```

- [ ] **Step 2: Create `observability/dashboards/pod-resource-usage.json`**

```json
{
  "title": "Pod Resource Usage",
  "uid": "pod-resource-usage",
  "tags": ["tenant", "resources"],
  "panels": [
    {
      "type": "timeseries",
      "title": "CPU usage per tenant namespace",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        {
          "expr": "sum by (namespace) (rate(container_cpu_usage_seconds_total{namespace=~\"tenant-.*\"}[5m]))"
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "Memory usage per tenant namespace",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "targets": [
        {
          "expr": "sum by (namespace) (container_memory_working_set_bytes{namespace=~\"tenant-.*\"})"
        }
      ]
    }
  ]
}
```

- [ ] **Step 3: Create `observability/alerts/boutique-alerts.yaml`**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: boutique-alerts
  namespace: observability
  labels:
    release: kube-prometheus-stack
spec:
  groups:
    - name: boutique.rules
      rules:
        - alert: TenantPodCrashLooping
          expr: increase(kube_pod_container_status_restarts_total{namespace=~"tenant-.*"}[15m]) > 3
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} in {{ $labels.namespace }} is crash-looping"
        - alert: TenantHighMemoryUsage
          expr: sum by (namespace) (container_memory_working_set_bytes{namespace=~"tenant-.*"}) > 800Mi
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Namespace {{ $labels.namespace }} memory usage is high"
```

- [ ] **Step 4: Apply dashboards as labeled ConfigMaps and update Makefile**

```makefile
.PHONY: dashboards

dashboards:
	kubectl -n observability create configmap tenant-red-metrics-dashboard \
		--from-file=tenant-red-metrics.json=observability/dashboards/tenant-red-metrics.json \
		--dry-run=client -o yaml | kubectl label -f - --local -o yaml grafana_dashboard=1 | kubectl apply -f -
	kubectl -n observability create configmap pod-resource-usage-dashboard \
		--from-file=pod-resource-usage.json=observability/dashboards/pod-resource-usage.json \
		--dry-run=client -o yaml | kubectl label -f - --local -o yaml grafana_dashboard=1 | kubectl apply -f -
	kubectl apply -f observability/alerts/boutique-alerts.yaml

observability: dashboards
```

(The `observability: dashboards` line makes `dashboards` run as a prerequisite of the existing `observability` target from Task 7, so `make observability` installs the stack and loads the dashboards/alerts in one step.)

- [ ] **Step 5: Verify**

Run: `make observability`
Expected: `kubectl get configmap -n observability -l grafana_dashboard=1` lists both dashboard ConfigMaps; `kubectl get prometheusrule -n observability` lists `boutique-alerts`. In the Grafana UI, both dashboards appear under Dashboards within ~1 minute (sidecar poll interval).

- [ ] **Step 6: Commit**

```bash
git add observability/dashboards observability/alerts Makefile
git commit -m "Add custom Grafana dashboards and Prometheus alert rules"
```

---

## Task 9: Smoke test script

**Files:**
- Create: `scripts/smoke-test.sh`
- Modify: `Makefile` (append `smoke-test` target)
- Test: run the script itself against a live cluster

**Interfaces:**
- Consumes: ArgoCD Applications from Task 4 (`boutique-acme`, `boutique-globex`, `boutique-initech`), tenant namespaces from Task 5.
- Produces: exit code 0 on success, non-zero with a printed reason on failure — consumed by Task 10's CI workflow.

- [ ] **Step 1: Create `scripts/smoke-test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

TENANTS=(acme globex initech)
FAILED=0

echo "== Checking ArgoCD Application health =="
for tenant in "${TENANTS[@]}"; do
  app="boutique-${tenant}"
  health=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "MISSING")
  sync=$(kubectl -n argocd get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "MISSING")
  echo "  $app: health=$health sync=$sync"
  if [[ "$health" != "Healthy" || "$sync" != "Synced" ]]; then
    echo "  FAIL: $app is not Healthy/Synced"
    FAILED=1
  fi
done

echo "== Checking tenant pods are Running =="
for tenant in "${TENANTS[@]}"; do
  ns="tenant-${tenant}"
  not_running=$(kubectl get pods -n "$ns" --field-selector=status.phase!=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
  total=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  echo "  $ns: $total pods total, $not_running not Running"
  if [[ "$total" -eq 0 || "$not_running" -gt 0 ]]; then
    echo "  FAIL: $ns has no pods or has non-Running pods"
    FAILED=1
  fi
done

if [[ "$FAILED" -eq 1 ]]; then
  echo "SMOKE TEST FAILED"
  exit 1
fi

echo "SMOKE TEST PASSED"
```

- [ ] **Step 2: Make it executable and add Makefile target**

```makefile
.PHONY: smoke-test

smoke-test:
	chmod +x scripts/smoke-test.sh
	./scripts/smoke-test.sh
```

- [ ] **Step 3: Verify against a live cluster with tenants deployed**

Run: `make up && make argocd && make security && make deploy` (wait ~2 minutes for sync), then `make smoke-test`
Expected: prints per-tenant health/sync and pod counts, ends with `SMOKE TEST PASSED`, exit code 0.

- [ ] **Step 4: Verify failure path**

Run: `kubectl delete deployment -n tenant-acme --all` then `make smoke-test`
Expected: script reports `tenant-acme` has 0 pods or non-Running pods, ends with `SMOKE TEST FAILED`, exit code 1. Re-run `make deploy` afterward to let ArgoCD self-heal the namespace back to healthy.

- [ ] **Step 5: Commit**

```bash
git add scripts/smoke-test.sh Makefile
git commit -m "Add multi-tenant smoke test script"
```

---

## Task 10: CI pipeline (lint, validate, smoke test)

**Files:**
- Create: `.github/workflows/ci.yaml`
- Modify: `Makefile` (append `lint` target)
- Test: push to a branch/PR and observe the workflow run

**Interfaces:**
- Consumes: `charts/boutique` (Task 3), `argocd/` (Tasks 2 & 4), `security/` (Tasks 5 & 6), `scripts/smoke-test.sh` (Task 9).
- Produces: green/red check on GitHub PRs; no other task depends on this one.

- [ ] **Step 1: Add `lint` Makefile target**

```makefile
.PHONY: lint

lint:
	helm dependency update charts/boutique
	helm lint charts/boutique -f values/tenants/acme.yaml
	helm lint charts/boutique -f values/tenants/globex.yaml
	helm lint charts/boutique -f values/tenants/initech.yaml
```

- [ ] **Step 2: Create `.github/workflows/ci.yaml`**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  lint-and-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: azure/setup-helm@v4
        with:
          version: v3.16.2
      - name: Helm lint
        run: make lint
      - name: Install kubeconform
        run: |
          curl -sSL https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz | tar xz
          sudo mv kubeconform /usr/local/bin/
      - name: Validate rendered manifests
        run: |
          helm template acme charts/boutique -f values/tenants/acme.yaml | kubeconform -summary -ignore-missing-schemas
      - name: Validate raw manifests
        run: |
          kubeconform -summary -ignore-missing-schemas security/namespaces/*.yaml security/network-policies/*.yaml security/rbac/*.yaml security/kyverno-policies/*.yaml argocd/applicationset.yaml

  smoke-test:
    runs-on: ubuntu-latest
    needs: lint-and-validate
    steps:
      - uses: actions/checkout@v4
      - name: Create kind cluster
        uses: helm/kind-action@v1.10.0
        with:
          cluster_name: k8s-multi-tenant-platform
          config: kind-config.yaml
      - name: Install ArgoCD
        run: make argocd
      - name: Apply security baseline
        run: make security
      - name: Deploy tenants
        run: |
          sed -i "s#https://github.com/YOUR_GITHUB_USERNAME/k8s-multi-tenant-platform.git#https://github.com/${{ github.repository }}.git#; s#targetRevision: main#targetRevision: ${{ github.sha }}#" argocd/applicationset.yaml
          make deploy
      - name: Wait for sync
        run: sleep 90
      - name: Run smoke test
        run: make smoke-test
```

- [ ] **Step 3: Verify locally before pushing**

Run: `make lint`
Expected: `helm lint` passes with `0 chart(s) failed` for all three tenant value files.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yaml Makefile
git commit -m "Add CI pipeline: lint, validate, kind smoke test"
```

(The full workflow only turns green once this repo has a real `origin` remote — see Task 12 — since the `smoke-test` job checks out `${{ github.sha }}` for ArgoCD to sync against.)

---

## Task 11: README

**Files:**
- Create: `README.md`
- Test: manual read-through

**Interfaces:**
- Consumes: nothing (documentation only); this is the last content task before publishing.

- [ ] **Step 1: Write `README.md`**

```markdown
# k8s-multi-tenant-platform

A local, reproducible demo of a multi-tenant Kubernetes platform: GitOps
deployment, per-tenant isolation, observability, and policy-enforced
security — built to run entirely on a laptop via `kind`, no cloud account
required.

## What this demonstrates

- **GitOps multi-tenancy:** a single ArgoCD `ApplicationSet` deploys the
  same Helm chart into three independent tenant namespaces
  (`tenant-acme`, `tenant-globex`, `tenant-initech`), each with its own
  values (replica counts, resource sizing, feature flags).
- **Security hardening:** default-deny NetworkPolicies, per-tenant RBAC,
  Pod Security Standards (`restricted`), ResourceQuotas, and Kyverno
  admission policies enforced cluster-wide (require resource
  limits, disallow `:latest` image tags, require non-root containers).
- **Observability:** kube-prometheus-stack + Loki, with two hand-built
  Grafana dashboards and two Prometheus alert rules covering per-tenant
  resource usage and pod health.
- **CI:** every push lints Helm charts, validates manifests with
  `kubeconform`, and spins up a real `kind` cluster to run an end-to-end
  smoke test.

The workload is Google's open-source
[microservices-demo](https://github.com/GoogleCloudPlatform/microservices-demo)
("Online Boutique"); the platform wiring around it (multi-tenant GitOps,
hardening, observability) is original.

## Quickstart

```bash
make up            # create local kind cluster
make argocd        # install ArgoCD
make security      # namespaces, quotas, network policies, RBAC
make kyverno       # cluster-wide policy enforcement
make deploy        # ApplicationSet deploys the app to 3 tenants
make observability # Prometheus, Grafana, Loki, dashboards, alerts
make smoke-test    # verify everything is healthy
```

Or run it all at once:

```bash
make demo
```

Grafana: `kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80`, then visit `http://localhost:3000` (`admin`/`admin`).

Tear down: `make down`

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
Terraform, point ArgoCD's `destination.server` at it, and swap the
`kind`-specific bits (LoadBalancer type, storage class in the Loki
values) for cloud equivalents. Nothing in the ArgoCD/Helm/security/
observability layers is `kind`-specific.

## Repo layout

See `docs/superpowers/specs/2026-08-29-k8s-multi-tenant-platform-design.md`
for the full design rationale.
```

- [ ] **Step 2: Add a `demo` convenience target to the Makefile tying every prior target together**

```makefile
.PHONY: demo

demo: up argocd security kyverno deploy observability
	@echo "Waiting for ArgoCD to sync tenants..."
	sleep 90
	$(MAKE) smoke-test
```

- [ ] **Step 3: Commit**

```bash
git add README.md Makefile
git commit -m "Add README and end-to-end demo target"
```

---

## Task 12: Publish to GitHub

**Files:**
- Modify: `argocd/applicationset.yaml` (replace placeholder URL with the real one)
- Test: CI workflow run on GitHub

**Interfaces:**
- Consumes: everything from Tasks 1-11.
- Produces: the public repo — the deliverable this whole plan exists for.

- [ ] **Step 1: Create the GitHub repo** (via `gh repo create k8s-multi-tenant-platform --public --source=. --remote=origin` or the GitHub web UI — confirm with the user which GitHub account/organization to use before running this, since it creates a public, externally-visible resource)

- [ ] **Step 2: Update `argocd/applicationset.yaml`'s `repoURL`** to the real repo URL (replacing `YOUR_GITHUB_USERNAME`)

- [ ] **Step 3: Push**

```bash
git push -u origin main
```

- [ ] **Step 4: Verify CI**

Check the Actions tab on GitHub.
Expected: `lint-and-validate` and `smoke-test` jobs both pass (green).

- [ ] **Step 5: Commit the URL fix if not already included**

```bash
git add argocd/applicationset.yaml
git commit -m "Point ApplicationSet at the published repo"
git push
```

---

## Self-Review Notes

- **Spec coverage:** GitOps/ApplicationSet (Task 4), local kind runtime (Task 1), microservices-demo workload (Task 3), NetworkPolicies/RBAC/PSS/quotas (Task 5), Kyverno (Task 6), observability + dashboards + alerts (Tasks 7-8), CI lint/validate/smoke-test (Tasks 9-10), README (Task 11) — all spec sections are covered.
- **Type/name consistency checked:** tenant names (`acme`/`globex`/`initech`) and namespace naming (`tenant-<name>`) are consistent across Tasks 3-9; ArgoCD Application naming (`boutique-<tenant>`) matches between Task 4 and the Task 9 smoke test.
- **Resource-footprint risk (spec's open question):** addressed by keeping replica counts at 1-2 (Task 3), giving CI its own lightweight path that reuses the same Makefile targets, and documenting in Task 10 that the full stack (observability + Kyverno) may need Task 12's real GitHub credentials before CI goes green end-to-end.
