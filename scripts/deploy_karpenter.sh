#!/bin/bash
set -euxo pipefail

# Retrieve Terraform outputs
REGION=$(terraform output -raw aws_region)
CLUSTER_NAME=$(terraform output -raw cluster_name)
KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)
CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
NODE_INSTANCE_ROLE_ARN=$(terraform output -raw node_instance_role_arn)

# Extract the role name from the ARN
NODE_INSTANCE_ROLE_NAME=$(echo $NODE_INSTANCE_ROLE_ARN | awk -F'/' '{print $NF}')

# Update kubeconfig
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

# Create the karpenter namespace
kubectl create namespace karpenter || true

# Create the service account for Karpenter
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: karpenter
  namespace: karpenter
  annotations:
    eks.amazonaws.com/role-arn: $KARPENTER_ROLE_ARN
EOF

# Install Karpenter using Helm
export KARPENTER_VERSION="0.16.3"

helm repo add karpenter https://charts.karpenter.sh/ || true
helm repo update

helm upgrade --install karpenter karpenter/karpenter \
  --namespace karpenter \
  --create-namespace \
  --version ${KARPENTER_VERSION} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter \
  --set clusterName=${CLUSTER_NAME} \
  --set clusterEndpoint=${CLUSTER_ENDPOINT} \
  --set aws.defaultInstanceProfile=${NODE_INSTANCE_ROLE_NAME} \
  --set controller.resources.requests.cpu=500m \
  --set controller.resources.requests.memory=512Mi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set replicas=1 \
  --wait || true

# Wait for Karpenter to be ready
kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n karpenter || true

# Wait additional time for webhook endpoints to be fully ready
echo "Waiting 30 seconds for Karpenter webhook endpoints to be ready..."
sleep 30

# Create EC2NodeClass
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1alpha1
kind: AWSNodeTemplate
metadata:
  name: default
spec:
  amiFamily: AL2
  instanceProfile: ${NODE_INSTANCE_ROLE_NAME}
  subnetSelector:
    karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelector:
    karpenter.sh/discovery: ${CLUSTER_NAME}
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
EOF

# Create NodePool
kubectl apply -f kubernetes/karpenter/nodepool.yaml

# Deploy test deployment (starts at 0 replicas)
kubectl apply -f kubernetes/karpenter/test-deployment.yaml

echo "Karpenter installation completed successfully!"
echo ""
echo "To verify Karpenter is running:"
echo "kubectl get pods -n karpenter"
echo ""
echo "To view Karpenter logs:"
echo "kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter"
echo ""
echo "To test autoscaling, run:"
echo "./scripts/test_karpenter.sh"
