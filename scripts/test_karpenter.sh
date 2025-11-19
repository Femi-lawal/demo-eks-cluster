#!/bin/bash
set -euxo pipefail

echo "Scaling up the inflate deployment to trigger Karpenter provisioning..."

# Scale up the deployment to trigger node provisioning
kubectl scale deployment inflate --replicas=5 -n default

echo ""
echo "Deployment scaled to 5 replicas. Karpenter will provision nodes in ~30-60 seconds."
echo ""
echo "Monitor with these commands:"
echo "  kubectl get nodes -w"
echo "  kubectl get nodepool,ec2nodeclass"
echo "  kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter"
echo "  kubectl get pods -o wide | grep inflate"
