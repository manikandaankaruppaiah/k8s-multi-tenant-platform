CLUSTER_NAME := k8s-multi-tenant-platform

.PHONY: up down argocd deploy security kyverno observability dashboards smoke-test lint

up:
	kind create cluster --name $(CLUSTER_NAME) --config kind-config.yaml
	kubectl cluster-info --context kind-$(CLUSTER_NAME)

down:
	kind delete cluster --name $(CLUSTER_NAME)

argocd:
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -k argocd/install
	kubectl -n argocd wait --for=condition=available --timeout=300s deployment/argocd-server

deploy:
	kubectl apply -f argocd/applicationset.yaml

security:
	kubectl apply -f security/namespaces/
	kubectl apply -f security/network-policies/
	kubectl apply -f security/rbac/

kyverno:
	helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
	helm repo update
	helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait
	kubectl apply -f security/kyverno-policies/

dashboards:
	kubectl -n observability create configmap tenant-red-metrics-dashboard \
		--from-file=tenant-red-metrics.json=observability/dashboards/tenant-red-metrics.json \
		--dry-run=client -o yaml | kubectl label -f - --local -o yaml grafana_dashboard=1 | kubectl apply -f -
	kubectl -n observability create configmap pod-resource-usage-dashboard \
		--from-file=pod-resource-usage.json=observability/dashboards/pod-resource-usage.json \
		--dry-run=client -o yaml | kubectl label -f - --local -o yaml grafana_dashboard=1 | kubectl apply -f -
	kubectl apply -f observability/alerts/boutique-alerts.yaml

observability:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo add grafana https://grafana.github.io/helm-charts --force-update
	helm repo update
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
		-n observability --create-namespace -f observability/install/kube-prometheus-stack-values.yaml --wait --timeout 10m
	helm upgrade --install loki grafana/loki \
		-n observability -f observability/install/loki-values.yaml --wait --timeout 10m
	$(MAKE) dashboards

smoke-test:
	chmod +x scripts/smoke-test.sh
	./scripts/smoke-test.sh

lint:
	helm dependency update charts/boutique
	helm lint charts/boutique -f values/tenants/acme.yaml
	helm lint charts/boutique -f values/tenants/globex.yaml
	helm lint charts/boutique -f values/tenants/initech.yaml
