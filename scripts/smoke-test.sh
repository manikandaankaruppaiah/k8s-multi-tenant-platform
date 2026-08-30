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
