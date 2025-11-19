#!/bin/bash
set -euxo pipefail

echo "Scaling down the inflate deployment..."

# Scale down the deployment
kubectl scale deployment inflate --replicas=0 -n default

echo ""
echo "Deployment scaled to 0 replicas."
echo "Watch nodes with: kubectl get nodes -w"
echo "Karpenter should remove empty nodes in about 30 seconds (consolidateAfter: 30s)"
echo ""
echo "Monitor Karpenter logs with:"
echo "kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter"
