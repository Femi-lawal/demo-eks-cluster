#!/bin/bash
set -euxo pipefail

echo "Scaling down the inflate deployment..."

# Scale down the deployment
kubectl scale deployment inflate --replicas=0 -n default

echo ""
echo "Deployment scaled to 0 replicas."
echo "Watch nodes with: kubectl get nodes -w"
echo "Karpenter should remove the empty node in about 30 seconds (ttlSecondsAfterEmpty)"
