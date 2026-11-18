#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl wait --for=condition=Ready nodes --all --timeout=300s >&2
kubectl -n kube-system rollout status deployment/coredns --timeout=300s >&2
kubectl -n tigera-operator rollout status deployment/tigera-operator --timeout=300s >&2
kubectl -n calico-system rollout status daemonset/calico-node --timeout=300s >&2
kubectl -n calico-system rollout status deployment/calico-kube-controllers --timeout=300s >&2
kubectl get --raw=/readyz >&2
kubectl get nodes -o json
