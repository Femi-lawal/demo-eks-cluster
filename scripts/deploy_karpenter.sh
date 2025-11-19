#!/bin/bash
set -euxo pipefail

# Retrieve Terraform outputs
REGION=$(terraform output -raw aws_region)
CLUSTER_NAME=$(terraform output -raw cluster_name)
KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)
CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)
NODE_INSTANCE_PROFILE_NAME=$(terraform output -raw node_instance_profile_name)

# NOTE: In Karpenter v1.7.0+, EC2NodeClass uses the IAM role name directly
# The role field expects the IAM role name, not the instance profile ARN

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

# Install Karpenter using Helm with OCI registry
export KARPENTER_VERSION="1.7.0"

# Logout and login to ECR public registry to ensure fresh authentication
aws ecr-public get-login-password --region us-east-1 | helm registry login --username AWS --password-stdin public.ecr.aws || true

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --create-namespace \
  --version ${KARPENTER_VERSION} \
  --set serviceAccount.create=false \
  --set serviceAccount.name=karpenter \
  --set settings.clusterName=${CLUSTER_NAME} \
  --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \
  --set controller.resources.requests.cpu=500m \
  --set controller.resources.requests.memory=512Mi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --set replicas=1 \
  --wait

# Wait for Karpenter to be ready
kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n karpenter || true

# Wait additional time for webhook endpoints to be fully ready
echo "Waiting 30 seconds for Karpenter webhook endpoints to be ready..."
sleep 30

# Get AWS Account ID for EC2NodeClass
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
NODE_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/$(echo ${NODE_INSTANCE_PROFILE_NAME})"

# Create EC2NodeClass (v1 API) - replaces AWSNodeTemplate
cat <<EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: karpenter-default
spec:
  amiFamily: AL2
  amiSelectorTerms:
    - alias: al2@latest
  role: "${NODE_INSTANCE_PROFILE_NAME}"  # In v1, we specify the IAM role name
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: ${CLUSTER_NAME}
  securityGroupSelectorTerms:
    - tags:
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
