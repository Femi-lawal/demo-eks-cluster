In this article, we will integrate Cluster Autoscaler, which will enable our cluster to adjust the number of nodes based on demand. We will need to make some adjustments to our EKS module.

## Prerequisites

Ensure you have:

- An active AWS account
- Terraform installed and configured
- Helm installed
- kubectl

## Setup Overview

## Prepare Your EKS Cluster

Ensure your EKS cluster is ready. If needed, [refer back to our guide on setting up an EKS cluster using Terraform](https://dev.to/aws-builders/navigating-aws-eks-with-terraform-understanding-eks-cluster-configuration-2f6o)

## Modifications

To enhance flexibility and customization, we've introduced new variables that streamline the addition of role and user mappings to the Kubernetes aws-auth ConfigMap. Additionally, to support Cluster Autoscaler's auto-discovery feature, it is essential to include specific tags in the launch configuration. We have also incorporated a variable to manage the Kubernetes version for the EKS cluster, allowing for more controlled upgrades and maintenance.

```terraform
variable "additional_role_mappings" {
  description = "Additional role mappings for aws-auth ConfigMap"
  type = list(object({
    rolearn  = string
    username = string
    groups   = list(string)
  }))
  default = []
}

variable "additional_user_mappings" {
  description = "Additional user mappings for aws-auth ConfigMap"
  type = list(object({
    userarn  = string
    username = string
    groups   = list(string)
  }))
  default = []
}

variable "eks_cluster_version" {
  description = "The desired Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "additional_launch_template_tags" {
  description = "Additional tags to apply to the launch template"
  type = map(string)
  default = {}
}
```

## Create IAM Role for Cluster Autoscaler

The autoscaler needs specific permissions to interact with EC2 instances and AWS services.
We will use recommended permissions from [the documentation](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md#full-cluster-autoscaler-features-policy-recommended)

```terraform
############################################################################################################
### AUTOSCALING
############################################################################################################
data "aws_iam_policy_document" "cluster_autoscaler_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }

    principals {
      identifiers = ["${module.eks.oidc_provider_arn}"]
      type        = "Federated"
    }
  }
}

# IAM Role for Cluster Autoscaler
resource "aws_iam_role" "cluster_autoscaler_role" {
  name               = "${var.cluster_name}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume_role_policy.json
}

# Custom policy for Cluster Autoscaler
data "aws_iam_policy_document" "cluster_autoscaler_policy" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup"
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "cluster_autoscaler_policy" {
  name   = "${var.cluster_name}-cluster-autoscaler-policy"
  role   = aws_iam_role.cluster_autoscaler_role.id
  policy = data.aws_iam_policy_document.cluster_autoscaler_policy.json
}
```

We can then pass the role mapping to the config map in the module, as well as the tags needed for auto-discovery

```terraform
module "eks" {
  source = "./modules/aws/eks/v1"

  region          = var.region
  cluster_name    = var.cluster_name
  private_subnets = module.vpc.private_subnets
  public_subnets  = module.vpc.public_subnets
  vpc_id          = module.vpc.vpc_id

  managed_node_groups = {
    demo_group = {
      name           = "demo-node-group"
      desired_size   = 2
      min_size       = 1
      max_size       = 3
      instance_types = ["t3a.small"]
    }
  }

  additional_role_mappings = [
    {
      rolearn  = aws_iam_role.cluster_autoscaler_role.arn
      username = "system:serviceaccount:kube-system:cluster-autoscaler"
      groups   = ["system:masters"]
    }
  ]

  additional_launch_template_tags = {
      "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      "k8s.io/cluster-autoscaler/enabled"             = "true"
  }
}
```

We can then apply our changes with terraform

```bash
terraform apply
```

![Successful terraform apply](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/39q6pnb1082dto674xkf.png)

We can confirm our cluster is up and running in the AWS console.

![Cluster in AWS](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/xnzcg5v0pua2w7dj3d60.png)

## Install Cluster Autoscaler using Helm

We have created the role mapping that the cluster-autoscaler service account will use, but we still need to create the actual service account, the manifest to create that will look like this

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::<ACCOUNT_ID>:role/<IAM_ROLE_NAME>"
```

For simplicity (or just because I'm lazy), I have created four scripts to help with the rest of the article. They make use of terraform outputs to avoid me having to put placeholders or keep track of which command I have to run first.

An explanation of what is happening is that our kubectl context is updated to that of the cluster, the service account for cluster autoscaler is created, and cluster autoscaler is deployed using helm.

```bash
#!/bin/bash
set -euxo pipefail

# Retrieve Terraform outputs
REGION=$(terraform output -raw aws_region)
CLUSTER_NAME=$(terraform output -raw cluster_name)
CLUSTER_AUTOSCALER_ROLE_ARN=$(terraform output -raw cluster_autoscaler_role_arn)

# Update kubeconfig
aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

# Create the service account for cluster autoscaler
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: $CLUSTER_AUTOSCALER_ROLE_ARN
EOF

# Deploy the cluster autoscaler Helm chart
helm repo add autoscaler https://kubernetes.github.io/autoscaler || true
helm repo update

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=$CLUSTER_NAME \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set awsRegion=$REGION \
  --set extraArgs.balance-similar-node-groups=true \
  --set extraArgs.skip-nodes-with-system-pods=false \
  --set extraArgs.expander=least-waste || true
```

I also deployed kubernetes dashboard just so we can have an application with a user interface we can interact with running on the cluster, and to confirm what we are seeing on the AWS dashboard regarding our cluster. This where the kube proxy add on comes in handy.

```bash
# Deploy the Kubernetes Dashboard
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.5.1/aio/deploy/recommended.yaml || true

# Create the admin-user service account and cluster role binding
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

# Get the token for the admin-user
kubectl -n kubernetes-dashboard create token admin-user || true

# Print the Kubernetes Dashboard URL
echo "Kubernetes Dashboard URL: http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"

# Start a kubectl proxy to access the Kubernetes Dashboard
kubectl proxy --port=8001
```

![Token and link](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/pq5tbs080pmcwbadb36j.png)

We can see the token and a link to view the dashboard via kube proxy

![kubernetes Dashboard login](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/61uyqfvoleyqiw4wc63k.png)

You can follow the link in the command and enter the token to access the dashboard and keep track of events. You will notice that we only have two nodes at the moment.

![Kubernetes Dashboard Nodes](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/btoko39ysn2wzsx3jkph.png)

This matches what we see in the AWS console.

![AWS Console Nodes](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/3facbjf3hsfh24strpwy.png)

## Deploy Applications To Trigger Scale Up Operation

Next, we will deploy Prometheus and Grafana to the cluster, but because of how little CPU and Memory the EC2 type we selected has, the deployments will fail to reach a healthy state. Cluster autoscale will come to the rescue and deploy an additional node to make our cluster healthy again.

I am also using a script to accomplish the deployments with helm

```bash
#!/bin/bash
set -euxo pipefail


# Deploy the metrics server Helm chart
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server || true
helm repo update

helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args[0]="--kubelet-insecure-tls" \
  --set args[1]="--kubelet-preferred-address-types=InternalIP" || true

# Deploy Prometheus and Grafana using the kube-prometheus-stack Helm chart
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts || true
helm repo update

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.enabled=true \
  --set grafana.adminPassword='admin' \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set defaultRules.create=true \
  --set alertmanager.enabled=false || true

# Ensure Prometheus is scraping metrics from the cluster autoscaler and metrics server
cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: cluster-autoscaler
  endpoints:
  - port: http
    interval: 30s
EOF

cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: metrics-server
  namespace: kube-system
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      k8s-app: metrics-server
  endpoints:
  - port: https
    interval: 30s
    tlsConfig:
      insecureSkipVerify: true
EOF
```

![Command Result](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/3cup83w57qvj2yubh2jt.png)

You will notice that cluster autoscaler did it's job and added an extra node to our cluster, the deployments were able to succeed after their initial failure

![AWS Console View](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/tt4k7mpec0tdw0n0g3em.png)

If you check the events of your cluster, you will be able to find the scale up events.

![Scale Up Event](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/gwesq65md6umq1dt83y9.png)

## Scale Down Operation

Now we will delete the Prometheus and Grafana applications and watch to see if cluster autoscaler scales down the cluster.
Once again I am using a script for the deletes

```bash
#!/bin/bash
set -euxo pipefail

# Delete the metrics server Helm release
helm uninstall metrics-server --namespace kube-system || true

# Delete Prometheus and Grafana Helm release
helm uninstall prometheus --namespace monitoring || true

# Delete the ServiceMonitor for cluster autoscaler
kubectl delete servicemonitor cluster-autoscaler --namespace kube-system --ignore-not-found=true

# Delete the ServiceMonitor for metrics server
kubectl delete servicemonitor metrics-server --namespace kube-system --ignore-not-found=true

# Delete the monitoring namespace
kubectl delete namespace monitoring --ignore-not-found=true
```

![Command Result](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/it2mnr4s9s468g7srsg1.png)

Cluster Autoscaler might scale down our cluster back to two Nodes immediately, or it might modify our desired number of nodes in our node group to require three nodes because of how weak the EC2 instance types we selected are, which is what happened in this case.

![AWS Console](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/s08bf8mi3mi7gzy7fq0y.png)

After some minutes of no new activity, cluster autoscaler scales down the cluster back to two Nodes.

![Scale Down Event](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/4raedhno2c52ddzj1s5z.png)

It also changes the desired size of our node group back to two nodes.

![AWS Console View](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/792ovgtq5isy1siljdxc.png)

The complete code used in this article can be found on [this branch of the repository](https://github.com/Femi-lawal/demo-eks-cluster/tree/feature/cluster-autoscaler)

## Conclusion

Your EKS cluster now has a functioning Cluster Autoscaler that is adept at scaling node resources in response to workload changes.
Don't forget to clean up any resources you are not using, it can get quite expensive.

- For advanced configurations and best practices, refer to the [Cluster Autoscaler documentation on AWS](https://github.com/kubernetes/autoscaler/blob/master/cluster-autoscaler/cloudprovider/aws/README.md).
