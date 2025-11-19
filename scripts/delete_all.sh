#!/bin/bash
set -euxo pipefail

echo "Cleaning up Karpenter resources..."

# Scale down the test deployment
kubectl scale deployment inflate --replicas=0 -n default || true

# Wait for Karpenter to deprovision nodes
echo "Waiting 90 seconds for Karpenter to deprovision nodes..."
sleep 90

# Delete the test deployment
kubectl delete deployment inflate -n default || true

# Delete NodePools (v1 API)
kubectl delete nodepool --all || true

# Delete EC2NodeClasses (v1 API)
kubectl delete ec2nodeclass --all || true

# Uninstall Karpenter Helm release
helm uninstall karpenter -n karpenter || true

# Delete the karpenter namespace
kubectl delete namespace karpenter || true

echo "Karpenter resources cleaned up!"
echo ""
echo "Checking for any remaining Karpenter-provisioned EC2 instances..."
aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/managed-by,Values=$(terraform output -raw cluster_name)" \
            "Name=instance-state-name,Values=running,stopping,stopped" \
  --region $(terraform output -raw aws_region) \
  --query 'Reservations[*].Instances[*].[InstanceId,State.Name]' \
  --output table || true

echo ""
echo "If any instances are shown above, terminate them with:"
echo "aws ec2 terminate-instances --instance-ids <instance-id> --region $(terraform output -raw aws_region)"
echo ""
echo "To destroy all infrastructure, run:"
echo "terraform destroy -auto-approve"
