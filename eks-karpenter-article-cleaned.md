# Navigating AWS EKS with Terraform: Configuring Karpenter for Just-in-Time Node Provisioning

_Author: Oluwafemi Lawal_

_Series: Navigating AWS EKS with Terraform_

In the [previous part of the series](https://dev.to/aws-builders/navigating-aws-eks-with-terraform-implementing-cluster-auoscaler-in-your-eks-cluster-p54), we installed and configured the **Kubernetes Cluster Autoscaler (CA)** on an EKS cluster provisioned with Terraform. That article showed how to let Kubernetes resize **existing** node groups when Pods can't be scheduled.In the previous part of the series, we installed and configured the **Kubernetes Cluster Autoscaler (CA)** on an EKS cluster provisioned with Terraform. That article showed how to let Kubernetes resize **existing** node groups when Pods can’t be scheduled.

In this article, we'll set up **Karpenter** — an open-source autoscaling solution from AWS that goes beyond resizing. Instead of only scaling node groups you've already created, **Karpenter talks directly to AWS and launches the _right_ EC2 instances on demand** to fit the Pods that are actually pending.In this article, we’ll set up **Karpenter** — an autoscaling solution from AWS that goes beyond resizing. Instead of only scaling node groups you’ve already created, **Karpenter talks directly to AWS and launches the _right_ EC2 instances on demand** to fit the Pods that are actually pending.

We will:We will:

1. Reuse the EKS cluster and OIDC setup from earlier articles.1. Reuse the EKS cluster and OIDC setup from earlier articles.

2. Create the Karpenter IAM role and policies with Terraform.2. Create the Karpenter IAM role and policies with Terraform.

3. Install Karpenter into the cluster using Helm.3. Install Karpenter into the cluster.

4. Create a NodePool and EC2NodeClass that tells Karpenter what kinds of instances it's allowed to create.4. Create a Provisioner (or NodePool) that tells Karpenter what kinds of instances it’s allowed to create.

5. Test that a pending Pod triggers Karpenter to create a new node.5. Test that a pending Pod triggers Karpenter to create a new node.

6. Observe how Karpenter automatically removes nodes when they're no longer needed.

This keeps the same “Terraform-first” style you used for the Cluster Autoscaler article, so it fits into your repo.

This keeps the same "Terraform-first" style you used for the Cluster Autoscaler article, so it fits seamlessly into your repo.

---

---

## 1. Why Karpenter When We Already Have Cluster Autoscaler?

## 1. Why Karpenter When We Already Have Cluster Autoscaler?

Cluster Autoscaler works best when:

Cluster Autoscaler works best when:- you know your instance types ahead of time

- You know your instance types ahead of time- you manage node groups in Terraform

- You manage node groups in Terraform- you just want to scale those groups up and down

- You just want to scale those groups up and down

Karpenter is better when:

Karpenter is better when:- workloads are diverse (CPU, memory, AZs)

- Workloads are diverse (CPU, memory, availability zones)- you want to use Spot easily

- You want to use Spot instances easily- you don’t want to manage many node groups

- You don't want to manage many node groups- you want faster scale-out

- You want faster scale-out (seconds vs minutes)

- You need bin-packing optimization across different instance typesSo think of this as the “modern autoscaling” counterpart to your CA article.

So think of this as the "modern autoscaling" counterpart to your CA article. Karpenter makes provisioning decisions based on the actual Pod requirements rather than scaling predefined node groups.---

---

## 2. Prerequisites

You should already have:

- An **EKS cluster** (from your [previous Terraform articles](https://dev.to/aws-builders/navigating-aws-eks-with-terraform-understanding-eks-cluster-configuration-2f6o))
- **OIDC** enabled on the cluster (we used this for IRSA before)
- `kubectl` and `helm` installed locally
- A place in your repo to drop new Terraform files (e.g. root of `demo-eks-cluster`)
- Terraform configured with your AWS credentials

If you're following along from the Cluster Autoscaler article, we'll be creating a new branch called `feature/karpenter` to implement these changes.

---

## 3. Prepare Your EKS Cluster

---Create a new file at the root of your repo, for example **`karpenter-irsa.tf`**:

## 3. Prepare Your EKS Cluster```hcl

#############################################

Before we dive into Karpenter-specific resources, we need to make a few modifications to our EKS cluster configuration to support Karpenter's discovery mechanism.# karpenter-irsa.tf

#############################################

### Update EKS Module Tags

data "aws_caller_identity" "current" {}

Karpenter uses tags to discover subnets and security groups. We need to update our `eks.tf` file to add the appropriate tags:

data "aws_eks_cluster" "this" {

````hcl name = var.cluster_name

module "eks" {}

  source = "./modules/aws/eks/v1"

# Build the OIDC provider ARN from the existing cluster

  region              = var.regiondata "aws_iam_openid_connect_provider" "this" {

  cluster_name        = var.cluster_name  arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}"

  private_subnets     = module.vpc.private_subnets}

  public_subnets      = module.vpc.public_subnets

  vpc_id              = module.vpc.vpc_idlocals {

  eks_cluster_version = "1.31"  karpenter_namespace       = "karpenter"

  karpenter_service_account = "karpenter"

  managed_node_groups = {}

    demo_group = {

      name           = "demo-node-group"data "aws_iam_policy_document" "karpenter_assume_role" {

      desired_size   = 2  statement {

      min_size       = 1    actions = ["sts:AssumeRoleWithWebIdentity"]

      max_size       = 3

      instance_types = ["t3a.small"]    principals {

    }      type        = "Federated"

  }      identifiers = [data.aws_iam_openid_connect_provider.this.arn]

    }

  additional_launch_template_tags = {

    "karpenter.sh/discovery" = var.cluster_name    condition {

  }      test     = "StringEquals"

}      variable = "${replace(data.aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")}:sub"

```      values   = ["system:serviceaccount:${local.karpenter_namespace}:${local.karpenter_service_account}"]

    }

The key change here is replacing the Cluster Autoscaler specific tags with `karpenter.sh/discovery`. This tag allows Karpenter to discover which subnets and security groups it should use when provisioning nodes.  }

}

---

resource "aws_iam_role" "karpenter" {

## 4. Terraform: IAM for Karpenter  name               = "${var.cluster_name}-karpenter"

  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role.json

Create a new file at the root of your repo called **`karpenter.tf`**. This file will contain all the IAM resources needed for Karpenter to function.}



```hcl# Attach the AWS-managed Karpenter policy

############################################################################################################resource "aws_iam_role_policy_attachment" "karpenter_controller" {

### KARPENTER  role       = aws_iam_role.karpenter.name

############################################################################################################  policy_arn = "arn:aws:iam::aws:policy/KarpenterControllerPolicy"

}

# IAM Role for Karpenter Controller

data "aws_iam_policy_document" "karpenter_assume_role_policy" {output "karpenter_iam_role_arn" {

  statement {  value = aws_iam_role.karpenter.arn

    actions = ["sts:AssumeRoleWithWebIdentity"]}

    effect  = "Allow"```



    condition {This reuses the EKS OIDC provider you already have and creates an IAM role only the Karpenter service account can assume.

      test     = "StringEquals"

      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:sub"---

      values   = ["system:serviceaccount:karpenter:karpenter"]

    }## 4. Install Karpenter with Helm



    principals {Create the namespace:

      identifiers = [module.eks.oidc_provider_arn]

      type        = "Federated"```bash

    }kubectl create namespace karpenter

  }```

}

Install Karpenter (replace values as needed):

resource "aws_iam_role" "karpenter_controller_role" {

  name               = "${var.cluster_name}-karpenter-controller"```bash

  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role_policy.jsonhelm repo add karpenter https://charts.karpenter.sh/

}helm repo update

````

helm install karpenter karpenter/karpenter --namespace karpenter --set serviceAccount.create=true --set serviceAccount.name=karpenter --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<KARPENTER_ROLE_ARN_FROM_TERRAFORM> --set settings.clusterName=${CLUSTER_NAME}

The Karpenter controller policy is comprehensive and gives Karpenter the permissions it needs to:```

- Launch and terminate EC2 instances

- Create and manage launch templatesYou can wrap this in a Terraform `helm_release` later to keep everything IaC.

- Describe EC2 resources (subnets, security groups, instance types, etc.)

- Manage instance profilesCheck:

- Tag resources appropriately

```bash

The full policy is quite extensive (covering EC2, IAM, SSM, and EKS actions), so I've included the complete version in the [repository](https://github.com/Femi-lawal/demo-eks-cluster/blob/feature/karpenter/karpenter.tf).kubectl get pods -n karpenter

```

### Update IAM Role Mappings

---

We also need to update the `eks.tf` file to include the Karpenter role in the aws-auth ConfigMap:

## 5. Create a Karpenter Provisioner

````hcl

additional_role_mappings = [Create `k8s/karpenter/provisioner-default.yaml`:

  {

    rolearn  = aws_iam_role.karpenter_controller_role.arn```yaml

    username = "system:serviceaccount:karpenter:karpenter"apiVersion: karpenter.sh/v1alpha5

    groups   = ["system:masters"]kind: Provisioner

  }metadata:

]  name: default

```spec:

  requirements:

### Update Terraform Outputs    - key: "karpenter.k8s.aws/instance-family"

      operator: In

Update your `ouput.tf` file to expose the necessary values for our deployment scripts:      values: ["t3", "t3a", "m5"]

    - key: "topology.kubernetes.io/zone"

```hcl      operator: In

output "karpenter_controller_role_arn" {      values: ["us-east-1a", "us-east-1b"]

  description = "The ARN of the Karpenter controller IAM role"  limits:

  value       = aws_iam_role.karpenter_controller_role.arn    resources:

}      cpu: 20

  ttlSecondsAfterEmpty: 120

output "cluster_endpoint" {  providerRef:

  description = "The endpoint for the EKS cluster"    name: default

  value       = module.eks.cluster_endpoint---

}apiVersion: karpenter.k8s.aws/v1alpha1

kind: AWSNodeTemplate

output "node_instance_role_arn" {metadata:

  description = "The ARN of the node instance role"  name: default

  value       = module.eks.node_instance_role_arnspec:

}  subnetSelector:

```    Name: "eks-private-*"

  securityGroupSelector:

### Apply Terraform Changes    aws:eks:cluster-name: "${CLUSTER_NAME}"

````

Now apply these changes:

Apply it:

````bash

terraform init```bash

terraform plankubectl apply -f k8s/karpenter/provisioner-default.yaml

terraform apply```

````

Adjust subnet and SG selectors to match your Terraform-created VPC resources.

You should see the new Karpenter IAM role and updated tags in your Terraform state.

---

---

## 4. Terraform: IAM for Karpenter

Create a new file at the root of your repo called **`karpenter.tf`**. This file will contain all the IAM resources needed for Karpenter to function.

```hcl
############################################################################################################
### KARPENTER
############################################################################################################

# IAM Role for Karpenter Controller
data "aws_iam_policy_document" "karpenter_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }

    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_role" "karpenter_controller_role" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role_policy.json
}
```

The Karpenter controller policy is comprehensive and gives Karpenter the permissions it needs to:

- Launch and terminate EC2 instances
- Create and manage launch templates
- Describe EC2 resources (subnets, security groups, instance types, etc.)
- Manage instance profiles
- Tag resources appropriately

The full policy is quite extensive (covering EC2, IAM, SSM, and EKS actions), so I've included the complete version in the [repository](https://github.com/Femi-lawal/demo-eks-cluster/blob/feature/karpenter/karpenter.tf).

### Update IAM Role Mappings

We also need to update the `eks.tf` file to include the Karpenter role in the aws-auth ConfigMap:

```hcl
additional_role_mappings = [
  {
    rolearn  = aws_iam_role.karpenter_controller_role.arn
    username = "system:serviceaccount:karpenter:karpenter"
    groups   = ["system:masters"]
  }
]
```

### Update Terraform Outputs

Update your `ouput.tf` file to expose the necessary values for our deployment scripts:

```hcl
output "karpenter_controller_role_arn" {
  description = "The ARN of the Karpenter controller IAM role"
  value       = aws_iam_role.karpenter_controller_role.arn
}

output "cluster_endpoint" {
  description = "The endpoint for the EKS cluster"
  value       = module.eks.cluster_endpoint
}

output "node_instance_role_arn" {
  description = "The ARN of the node instance role"
  value       = module.eks.node_instance_role_arn
}
```

### Apply Terraform Changes

Now apply these changes:

```bash
terraform init
terraform plan
terraform apply
```

You should see the new Karpenter IAM role and updated tags in your Terraform state.

---

## 5. Install Karpenter using Helm

Create a pod that can’t fit on current nodes:

Similar to the Cluster Autoscaler deployment, I've created a script to automate the Karpenter installation. Create a file called `scripts/deploy_karpenter.sh`:

````yaml

```bashapiVersion: v1

#!/bin/bashkind: Pod

set -euxo pipefailmetadata:

  name: karpenter-demo

# Retrieve Terraform outputsspec:

REGION=$(terraform output -raw aws_region)  containers:

CLUSTER_NAME=$(terraform output -raw cluster_name)    - name: pause

KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_controller_role_arn)      image: public.ecr.aws/eks-distro/kubernetes/pause:3.8

CLUSTER_ENDPOINT=$(terraform output -raw cluster_endpoint)      resources:

NODE_INSTANCE_ROLE_ARN=$(terraform output -raw node_instance_role_arn)        requests:

          cpu: "2"

# Extract the role name from the ARN          memory: "2Gi"

NODE_INSTANCE_ROLE_NAME=$(echo $NODE_INSTANCE_ROLE_ARN | awk -F'/' '{print $NF}')```



# Update kubeconfigApply:

aws eks update-kubeconfig --region $REGION --name $CLUSTER_NAME

```bash

# Create the karpenter namespacekubectl apply -f k8s/karpenter/test-pod.yaml

kubectl create namespace karpenter || true```



# Create the service account for KarpenterWatch Karpenter:

cat <<EOF | kubectl apply -f -

apiVersion: v1```bash

kind: ServiceAccountkubectl logs -n karpenter deployment/karpenter -f

metadata:kubectl get nodes -o wide

  name: karpenter```

  namespace: karpenter

  annotations:You should see a new node join to run the Pod.

    eks.amazonaws.com/role-arn: $KARPENTER_ROLE_ARN

EOF---



# Install Karpenter using Helm## 7. Cost Controls

export KARPENTER_VERSION="v0.37.0"

- Keep `limits.resources.cpu` small in the Provisioner.

helm repo add karpenter https://charts.karpenter.sh/ || true- Use `ttlSecondsAfterEmpty` so idle nodes are terminated.

helm repo update- Delete test Pods when done:

  ```bash

helm upgrade --install karpenter karpenter/karpenter \  kubectl delete pod karpenter-demo

  --namespace karpenter \  ```

  --create-namespace \

  --version ${KARPENTER_VERSION} \---

  --set serviceAccount.create=false \

  --set serviceAccount.name=karpenter \## 8. Summary

  --set settings.clusterName=${CLUSTER_NAME} \

  --set settings.clusterEndpoint=${CLUSTER_ENDPOINT} \- We used the same IRSA pattern from your cluster autoscaler article.

  --set settings.interruptionQueue=${CLUSTER_NAME} \- We created an IAM role for Karpenter with Terraform.

  --set controller.resources.requests.cpu=1 \- We installed Karpenter and annotated its service account with the IAM role.

  --set controller.resources.requests.memory=1Gi \- We created a Provisioner so Karpenter knows what to launch.

  --set controller.resources.limits.cpu=1 \- We verified it by forcing a pending Pod.

  --set controller.resources.limits.memory=1Gi \

  --wait || trueThis is a drop-in “Karpenter version” of your autoscaler article and fits the same EKS/Terraform storytelling style.


# Wait for Karpenter to be ready
kubectl wait --for=condition=available --timeout=300s deployment/karpenter -n karpenter || true
````

This script does several things:

1. Retrieves necessary values from Terraform outputs (avoiding hardcoded values)
2. Updates your kubectl context to point to the EKS cluster
3. Creates the Karpenter namespace and service account with the IRSA annotation
4. Installs Karpenter via Helm with appropriate configuration
5. Waits for Karpenter to become available

Make the script executable and run it:

```bash
chmod +x scripts/deploy_karpenter.sh
./scripts/deploy_karpenter.sh
```

Verify Karpenter is running:

```bash
kubectl get pods -n karpenter
```

You should see the Karpenter controller pod in a Running state.

---

## 6. Configure Karpenter Provisioner and AWSNodeTemplate

Now that Karpenter is installed, we need to tell it what kinds of nodes it's allowed to provision. For Karpenter v0.16.3, we use two main CRDs (Custom Resource Definitions):

1. **AWSNodeTemplate** (v1alpha1): Defines AWS-specific configuration (AMI family, subnets, security groups, IAM role)
2. **Provisioner** (v1alpha5): Defines the scheduling constraints and limits for nodes

> **Note on API Versions:** Karpenter v0.32.0+ uses newer API versions with `NodePool` (v1beta1) and `EC2NodeClass` (v1beta1). This implementation uses v0.16.3 with the older but stable `Provisioner` and `AWSNodeTemplate` APIs.

### AWSNodeTemplate

The AWSNodeTemplate tells Karpenter how to configure the EC2 instances it launches. In our deployment script, we dynamically create this:

```yaml
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
```

This configuration:

- Uses Amazon Linux 2 AMIs (`amiFamily: AL2`)
- References the existing node instance profile
- Uses tags to discover appropriate subnets and security groups
- Tags instances for easy identification

### Provisioner

Create `kubernetes/karpenter/nodepool.yaml`:

```yaml
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  requirements:
    - key: kubernetes.io/arch
      operator: In
      values: ["amd64"]
    - key: kubernetes.io/os
      operator: In
      values: ["linux"]
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["on-demand"]
    - key: karpenter.k8s.aws/instance-category
      operator: In
      values: ["t"]
    - key: karpenter.k8s.aws/instance-generation
      operator: Gt
      values: ["2"]
  providerRef:
    name: default
  limits:
    resources:
      cpu: 10
  ttlSecondsAfterEmpty: 30
  ttlSecondsUntilExpired: 2592000 # 30 days
```

This Provisioner configuration:

- Only provisions **amd64 Linux** nodes
- Uses **on-demand** instances (you can add "spot" for cost savings)
- Restricts to **t-family** instances (t3, t3a, etc.) **generation 3 or higher**
- Sets a CPU limit of **10 vCPUs** total across all Karpenter-provisioned nodes
- References the `default` AWSNodeTemplate via `providerRef`
- Automatically deprovisions nodes **30 seconds** after they become empty
- Expires nodes after **30 days** for security patching

The Provisioner is applied as part of the `deploy_karpenter.sh` script, but you can also apply it manually:

```bash
kubectl apply -f kubernetes/karpenter/nodepool.yaml
```

---

## 7. Test Karpenter with a Sample Workload

Now let's test that Karpenter can provision nodes on demand. We'll create a simple deployment that requests resources our existing nodes can't satisfy.

### Create Test Deployment

I've created `kubernetes/karpenter/test-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
  namespace: default
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: inflate
          image: public.ecr.aws/eks-distro/kubernetes/pause:3.7
          resources:
            requests:
              cpu: "1"
              memory: "1.5Gi"
```

This deployment starts with 0 replicas. Each pod requests 1 CPU and 1.5Gi of memory.

### Deploy and Scale Up

First, apply the deployment:

```bash
kubectl apply -f kubernetes/karpenter/test-deployment.yaml
```

Now use the test script to scale it up:

```bash
./scripts/test_karpenter.sh
```

This script scales the deployment to 5 replicas and provides commands to monitor the provisioning:

```bash
#!/bin/bash
set -euxo pipefail

echo "Scaling up the inflate deployment to trigger Karpenter provisioning..."

# Scale up the deployment to trigger node provisioning
kubectl scale deployment inflate --replicas=5 -n default

echo ""
echo "Deployment scaled to 5 replicas. Monitoring cluster events..."
```

### Monitor Karpenter Activity

Watch Karpenter logs to see it making provisioning decisions:

```bash
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter -c controller
```

You'll see logs like:

```
INFO    controller.provisioner  found provisionable pod(s)
INFO    controller.provisioner  computed new node(s) to fit pod(s)
INFO    controller.provisioner  created node with 1 pods requesting cpu=1000m, memory=1536Mi
```

Check nodes:

```bash
kubectl get nodes
```

You should see a new node appear that Karpenter provisioned!

View the pods:

```bash
kubectl get pods -n default -l app=inflate
```

All 5 pods should be running on the newly provisioned node.

---

## 8. Scale Down and Node Deprovisioning

One of Karpenter's best features is automatic deprovisioning. When nodes become empty or underutilized, Karpenter will automatically remove them.

### Scale Down the Deployment

Run the cleanup test script:

```bash
./scripts/cleanup_karpenter_test.sh
```

This scales the deployment back to 0:

```bash
kubectl scale deployment inflate --replicas=0 -n default
```

### Watch Automatic Deprovisioning

Monitor the nodes:

```bash
kubectl get nodes -w
```

After about 30 seconds (the default `ttlSecondsAfterEmpty` in Karpenter's consolidation settings), Karpenter will:

1. Cordon the empty node
2. Drain any remaining system pods
3. Terminate the EC2 instance

You'll see this in the Karpenter logs:

```
INFO    controller.deprovisioning   deprovisioning via emptiness delete
INFO    controller.deprovisioning   cordoned node
INFO    controller.deprovisioning   deleted node
```

This is a huge improvement over Cluster Autoscaler, which can take 10-15 minutes to scale down.

---

## 9. Understanding Karpenter's Advantages

Through this exercise, you've seen several advantages of Karpenter over Cluster Autoscaler:

### Faster Provisioning

Karpenter provisions nodes in **seconds** because it launches instances directly rather than scaling Auto Scaling Groups.

### No Pre-defined Node Groups

You don't need to define multiple node groups for different instance types. Karpenter chooses the best fit automatically.

### Better Bin Packing

Karpenter looks at all pending pods together and provisions nodes that maximize utilization.

### Faster Scale Down

Karpenter can deprovision nodes in **30-60 seconds** vs 10+ minutes for CA.

### Consolidation

Karpenter actively consolidates nodes to reduce costs, even moving pods to smaller instances when possible.

### Spot Instance Support

Adding spot instances is as simple as adding `"spot"` to the `karpenter.sh/capacity-type` values in your NodePool.

---

## 10. Cost Optimization Tips

Here are some ways to optimize costs with Karpenter:

### 1. Enable Spot Instances

Update your NodePool to include spot instances:

```yaml
- key: karpenter.sh/capacity-type
  operator: In
  values: ["on-demand", "spot"]
```

### 2. Set Appropriate Limits

Use the `limits` section to prevent runaway costs:

```yaml
limits:
  cpu: 20
  memory: 80Gi
```

### 3. Use Consolidation

The `consolidationPolicy: WhenUnderutilized` setting we used actively looks for opportunities to move pods to fewer or cheaper nodes.

### 4. Set Node TTL

The `expireAfter: 720h` setting forces nodes to be replaced every 30 days, which helps with security patching and prevents long-lived nodes.

### 5. Restrict Instance Types

We limited to t-family instances, but you can be even more specific:

```yaml
- key: node.kubernetes.io/instance-type
  operator: In
  values: ["t3a.small", "t3a.medium"]
```

---

## 11. Monitoring Karpenter in Action

To truly understand and validate Karpenter's autoscaling capabilities, you'll want to observe its behavior under load. Let's set up monitoring and run load tests to see Karpenter automatically provision and deprovision nodes.

### Setting Up Prometheus and Grafana

First, deploy a monitoring stack to visualize Karpenter's metrics and cluster behavior:

```bash
./scripts/deploy_monitoring.sh
```

This script deploys:

- **Prometheus**: Scrapes metrics from Karpenter and Kubernetes
- **Grafana**: Provides visualization dashboards
- **Load Testing Applications**: Pre-configured workloads for testing

Access Grafana dashboard:

```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000
```

Visit `http://localhost:3000` - the dashboard will show:

- Total node count over time
- Karpenter nodes created/terminated
- Pending pod count
- Pod distribution across nodes

### Load Testing Scenarios

The deployment includes several load testing scenarios:

#### 1. Small Load Test (3 CPU, 3Gi Memory)

```bash
./scripts/run_load_test.sh small
```

This provisions 3 pods, each requesting 1 CPU and 1Gi memory. Perfect for seeing Karpenter add a single additional node.

#### 2. Medium Load Test (~6.25 CPU, 6.5Gi Memory)

```bash
./scripts/run_load_test.sh medium
```

Deploys 5 load-generator pods + 3 web-app pods. Watch as Karpenter provisions 1-2 nodes to accommodate the workload.

#### 3. Large Load Test (~11.75 CPU, 10.5Gi Memory)

```bash
./scripts/run_load_test.sh large
```

Heavy load that will test the CPU limits defined in your Provisioner (10 CPU by default).

#### 4. Burst Load Test (10 Parallel Jobs)

```bash
./scripts/run_load_test.sh burst
```

Creates a Kubernetes Job with 10 parallel completions, simulating a batch processing workload.

### Observing Autoscaling in Real-Time

While a load test is running, open multiple terminals to observe different aspects:

**Terminal 1 - Watch Nodes:**

```bash
kubectl get nodes -L karpenter.sh/provisioner-name,node.kubernetes.io/instance-type -w
```

You'll see new nodes appear with `PROVISIONER-NAME: default` as Karpenter provisions them.

**Terminal 2 - Watch Pods:**

```bash
kubectl get pods -o wide -A | grep -E 'load-generator|web-app|burst-workload'
```

Watch pods transition from `Pending` → `ContainerCreating` → `Running` as nodes become available.

**Terminal 3 - Karpenter Logs:**

```bash
kubectl logs -f -n karpenter -l app.kubernetes.io/name=karpenter -c controller
```

See Karpenter's decision-making process in real-time:

```
INFO    controller.provisioning Found 5 provisionable pod(s)
INFO    controller.provisioning Computed 1 new node(s) will fit 5 pod(s)
INFO    controller.provisioning Launching node with 8 CPU, 32Gi memory
INFO    controller.provisioning Created launch template, launching instances
```

**Terminal 4 - Grafana Dashboard:**

```bash
kubectl port-forward -n monitoring svc/grafana 3000:3000
```

The Karpenter Autoscaling Dashboard shows:

- Node count graph increasing as load is applied
- Pod count showing pending pods drop to zero
- Karpenter metrics for nodes created

### Testing Scale-Down

After observing scale-up, test Karpenter's fast scale-down:

```bash
./scripts/stop_load_test.sh
```

This scales all test deployments to zero. Watch as:

1. Pods terminate immediately
2. Nodes become empty
3. After 30 seconds (the `ttlSecondsAfterEmpty` setting), Karpenter deprovisions the nodes
4. Only your original managed node group nodes remain

Watch the deprovisioning:

```bash
kubectl get nodes -L karpenter.sh/provisioner-name -w
```

You'll see Karpenter nodes disappear in about 30 seconds - much faster than Cluster Autoscaler's 10+ minute scale-down time!

### Understanding the Results

What you should observe:

**Provisioning Speed**: Nodes typically become ready in 60-90 seconds
**Instance Selection**: Karpenter chooses appropriate instance types (like t3a.2xlarge for CPU-intensive workloads)
**Bin Packing**: Multiple pods efficiently packed onto single nodes
**Scale-Down Speed**: Nodes deprovisioned in ~30 seconds after becoming empty
**Cost Optimization**: Only running nodes needed for current workload

### Cleanup

Remove the monitoring stack and load testing applications:

```bash
./scripts/cleanup_monitoring.sh
```

---

## 12. Troubleshooting

### Version Compatibility Issues

**Problem:** Karpenter v0.37.0 is not available in the Helm repository.

**Solution:** This implementation uses Karpenter v0.16.3, which is stable and well-tested. If you encounter version-related errors:

1. Check available versions:

   ```bash
   helm search repo karpenter/karpenter --versions
   ```

2. The API versions used in this setup are:

   - `karpenter.sh/v1alpha5` for Provisioner
   - `karpenter.k8s.aws/v1alpha1` for AWSNodeTemplate

3. For newer Karpenter versions (v0.32+), API versions changed to:
   - `karpenter.sh/v1beta1` for NodePool
   - `karpenter.k8s.aws/v1beta1` for EC2NodeClass

### Nodes Not Being Provisioned

**Problem:** Pods remain pending, but no new nodes appear.

**Troubleshooting steps:**

1. Check Karpenter logs:

   ```bash
   kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -c controller --tail=50
   ```

2. Verify IAM permissions - check if you see errors like:

   - `UnauthorizedOperation` - IAM policy is missing EC2 permissions
   - `AccessDenied` - IAM role trust relationship may be incorrect

3. Ensure discovery tags exist:

   ```bash
   # Check subnets
   aws ec2 describe-subnets --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" --region ${REGION}

   # Check security groups
   aws ec2 describe-security-groups --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" --region ${REGION}
   ```

4. If tags are missing, add them manually:

   ```bash
   # Tag a subnet
   aws ec2 create-tags --resources subnet-xxxxx --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}

   # Tag a security group
   aws ec2 create-tags --resources sg-xxxxx --tags Key=karpenter.sh/discovery,Value=${CLUSTER_NAME}
   ```

### IAM Policy Conditions Too Restrictive

**Problem:** Karpenter logs show `AccessDenied` errors when launching instances.

**Solution:** Earlier Karpenter versions (like v0.16.3) may have issues with overly restrictive IAM policy conditions. If you see errors, simplify the IAM policy by removing condition blocks that require specific tags like `karpenter.sh/nodepool`.

Our working `karpenter.tf` includes simplified conditions that work with v0.16.3.

### Pods Still Pending After Node Provisioned

**Problem:** New node appears but pods don't schedule.

**Troubleshooting steps:**

1. Check if the node is actually from Karpenter:

   ```bash
   kubectl get nodes -L karpenter.sh/provisioner-name
   ```

   Karpenter nodes will have a value in the PROVISIONER-NAME column.

2. Verify node resources:

   ```bash
   kubectl describe node <node-name> | grep -A5 "Allocatable"
   ```

3. Check pod resource requests match available capacity:
   ```bash
   kubectl describe pod <pod-name> | grep -A5 "Requests"
   ```

### Nodes Not Being Deprovisioned

**Problem:** Empty nodes remain after scaling down.

**Troubleshooting steps:**

1. Check the Provisioner configuration has TTL settings:

   ```yaml
   ttlSecondsAfterEmpty: 30
   ttlSecondsUntilExpired: 2592000 # 30 days
   ```

2. Verify nodes are actually empty:

   ```bash
   kubectl get pods --all-namespaces -o wide | grep <node-name>
   ```

3. Check for pods with local storage or anti-affinity rules that prevent eviction.

4. Review Karpenter logs for deprovisioning decisions:
   ```bash
   kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep -i "deprovision\|ttl\|empty"
   ```

### Helm Installation Fails

**Problem:** Helm install command fails with chart not found.

**Solution:**

1. Ensure repository is added and updated:

   ```bash
   helm repo add karpenter https://charts.karpenter.sh/
   helm repo update
   ```

2. For v0.16.3, use these Helm values format:

   ```bash
   --set clusterName=${CLUSTER_NAME}
   --set clusterEndpoint=${CLUSTER_ENDPOINT}
   ```

   Not the newer format:

   ```bash
   --set settings.clusterName=${CLUSTER_NAME}
   ```

---

## 13. Cleanup

When you're done testing, clean up the Karpenter resources:

```bash
./scripts/cleanup_karpenter.sh
```

This script:

- Scales down test deployments
- Deletes the NodePool and EC2NodeClass
- Uninstalls the Karpenter Helm release
- Removes the Karpenter namespace

If you want to destroy all infrastructure:

```bash
terraform destroy
```

**Important:** Karpenter-provisioned nodes should be cleaned up automatically when you delete the NodePool, but you may want to verify in the AWS console that no orphaned instances remain.

---

## 14. Comparison: Cluster Autoscaler vs Karpenter

| Feature                | Cluster Autoscaler | Karpenter      |
| ---------------------- | ------------------ | -------------- |
| **Provisioning Time**  | 2-5 minutes        | 30-60 seconds  |
| **Node Groups**        | Required           | Not required   |
| **Instance Selection** | Predefined         | Dynamic        |
| **Scale Down Time**    | 10+ minutes        | 30-60 seconds  |
| **Spot Support**       | Via ASG            | Native, simple |
| **Bin Packing**        | Limited            | Advanced       |
| **Consolidation**      | No                 | Yes            |
| **Configuration**      | Via ASG tags       | Via CRDs       |

---

## 15. Advanced Monitoring

To keep an eye on Karpenter's behavior in production, consider:

### View Karpenter Metrics

Karpenter exposes Prometheus metrics:

```bash
kubectl port-forward -n karpenter svc/karpenter 8080:8080
```

Then visit `http://localhost:8080/metrics`

### Key Metrics to Watch

- `karpenter_nodes_created_total` - Total nodes created
- `karpenter_nodes_terminated_total` - Total nodes terminated
- `karpenter_provisioner_scheduling_duration_seconds` - Time to provision
- `karpenter_deprovisioning_actions_performed_total` - Deprovision actions

### CloudWatch Logs

Karpenter logs are also available in CloudWatch under the `/aws/eks/<cluster-name>/cluster` log group.

---

## 16. Conclusion

You now have a fully functional Karpenter setup on your EKS cluster! Karpenter provides:

✅ **Faster autoscaling** - Nodes in seconds, not minutes  
✅ **Smarter provisioning** - Right-sized instances for your workloads  
✅ **Cost optimization** - Automatic consolidation and spot support  
✅ **Less management** - No need to pre-define node groups  
✅ **Terraform integration** - IAM roles and configuration via IaC

The complete code for this article is available on the [`feature/karpenter` branch](https://github.com/Femi-lawal/demo-eks-cluster/tree/feature/karpenter) of the demo repository.

### Next Steps

- Experiment with **spot instances** in your NodePool
- Set up **Prometheus monitoring** for Karpenter metrics
- Explore **multiple NodePools** for different workload types
- Configure **interruption handling** for spot instances
- Learn about **drift** for automatic node upgrades

For more advanced configurations and best practices, refer to:

- [Karpenter Documentation](https://karpenter.sh/)
- [AWS EKS Best Practices Guide - Karpenter](https://aws.github.io/aws-eks-best-practices/karpenter/)

Don't forget to clean up resources when you're done experimenting to avoid unnecessary AWS charges!

---

**Previous Article:** [Navigating AWS EKS with Terraform: Implementing Cluster Autoscaler in your EKS Cluster](https://dev.to/aws-builders/navigating-aws-eks-with-terraform-implementing-cluster-auoscaler-in-your-eks-cluster-p54)
