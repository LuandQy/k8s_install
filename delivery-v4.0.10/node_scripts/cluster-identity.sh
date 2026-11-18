#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
uid=$(kubectl get namespace kube-system -o jsonpath='{.metadata.uid}')
version=$(kubectl version -o json | jq -r '.serverVersion.gitVersion')
hash=$(openssl x509 -in /etc/kubernetes/pki/ca.crt -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 | awk '{print $NF}')
kubectl get nodes -o json | jq --arg uid "$uid" --arg version "$version" --arg hash "sha256:$hash" \
 '{uid:$uid,version:$version,discovery_ca_hash:$hash,nodes:[.items[]|{name:.metadata.name,version:.status.nodeInfo.kubeletVersion,arch:.status.nodeInfo.architecture,ips:[.status.addresses[]|select(.type=="InternalIP")|.address],ready:any(.status.conditions[];.type=="Ready" and .status=="True")} ]}'
