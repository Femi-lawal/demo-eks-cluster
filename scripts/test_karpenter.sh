#!/bin/bash
set -euxo pipefail

echo "Scaling up the inflate deployment to trigger Karpenter provisioning..."

# Scale up the deployment to trigger node provisioning
kubectl scale deployment inflate --replicas=5 -n default

echo ""
echo "Deployment scaled to 5 replicas. Monitoring cluster events..."
