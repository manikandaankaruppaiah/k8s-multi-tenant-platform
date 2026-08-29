CLUSTER_NAME := k8s-multi-tenant-platform

.PHONY: up down argocd deploy

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
