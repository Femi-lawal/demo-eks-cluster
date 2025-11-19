#!/bin/bash
set -euxo pipefail

echo "Cleaning up Karpenter resources..."

# Scale down the test deployment
kubectl scale deployment inflate --replicas=0 -n default || true

# Wait a bit for Karpenter to deprovision nodes
echo "Waiting 60 seconds for Karpenter to deprovision nodes..."
sleep 60

# Delete the test deployment
kubectl delete deployment inflate -n default || true

# Delete the Provisioner
kubectl delete provisioner default || true

# Delete the AWSNodeTemplate
kubectl delete awsnodetemplate default || true

# Uninstall Karpenter Helm release
helm uninstall karpenter -n karpenter || true

# Delete the karpenter namespace
kubectl delete namespace karpenter || true

echo "Karpenter resources cleaned up!"
echo ""
echo "To destroy all infrastructure, run:"
echo "terraform destroy"
