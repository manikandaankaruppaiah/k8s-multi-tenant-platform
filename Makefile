CLUSTER_NAME := k8s-multi-tenant-platform

.PHONY: up down argocd deploy security kyverno

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
