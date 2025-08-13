# eks-lab
# EKS Terraform Learning Lab (Core Components + Autoscaling)

A hands-on lab to stand up a small **Amazon EKS** cluster with Terraform, explore Kubernetes core components, and practice **pod autoscaling (HPA)** and **node autoscaling (Cluster Autoscaler)**. Designed for learning, not production.

---

## 1) Objectives — what you’ll learn

* How EKS maps to Kubernetes **core components** (API server, etcd, scheduler, controller-manager, kubelet, kube-proxy, CoreDNS).
* How to provision an EKS cluster with **Terraform** using community modules.
* How to enable **Horizontal Pod Autoscaler (HPA)** and **Cluster Autoscaler (CA)**.
* How to observe scaling behavior under load, and how to reason about capacity.

> Stretch: swap Cluster Autoscaler for **Karpenter** later (faster, bin-packing friendly), add AWS Load Balancer Controller, Prometheus/Grafana.

---

## 2) Architecture (minimal learning setup)

```
AWS
└─ VPC (3 AZs)
   ├─ Private subnets (for nodes + pods)
   ├─ Public subnets (optional/NAT egress)
   └─ NAT + IGW (egress)

EKS (managed control plane)
 ├─ API server, etcd, controller-manager, scheduler (AWS-managed)
 └─ Data plane: Managed Node Group (EC2)
      └─ kubelet, kube-proxy, CNI (Amazon VPC CNI), CoreDNS

Add-ons
 ├─ metrics-server (HPA needs CPU/mem metrics)
 └─ Cluster Autoscaler (scales node group size based on pending pods)
```

---

## 3) Prerequisites (verify first)

* **AWS account** with an admin-ish user/role. Default region: `us-east-1` (change as needed).
* **Terraform** ≥ 1.6, **awscli**, **kubectl**, **helm**.
* `aws configure` is set; you can run `aws sts get-caller-identity`.

---

## 4) Project layout

Use any layout you prefer. Here’s a simple, single-environment structure:

```
./eks-lab/
  ├─ main.tf
  ├─ variables.tf
  ├─ providers.tf
  ├─ outputs.tf
  ├─ terraform.tfvars           # your values
  ├─ k8s/
  │   ├─ demo-deploy.yaml       # sample app + HPA
  │   └─ loadgen.yaml           # simple load generator
  └─ README.md
```

---

## 5) Terraform code (copy/paste these files)

### providers.tf

### outputs.tf

```hcl
output "cluster_name" { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }
output "node_group_asg_tags" { value = module.eks.eks_managed_node_groups }
```

### terraform.tfvars (example)

```hcl
region        = "us-east-1"
cluster_name  = "eks-lab"
node_min      = 1
node_desired  = 2
node_max      = 5
node_instance_types = ["t3.large"]
```

---

## 6) Deploy

```bash
cd eks-lab
terraform init
terraform apply -auto-approve

# Update local kubeconfig
aws eks update-kubeconfig --name eks-lab --region us-east-1

# Sanity checks
kubectl get nodes -o wide
kubectl get po -n kube-system
kubectl get deployment -n kube-system cluster-autoscaler -o wide
```

**Map to core components:**

* Control plane (API server, etcd, scheduler, controller-manager) is **AWS-managed**. You won’t see these as pods.
* Data plane pods you *will* see in `kube-system`: **kube-proxy**, **coredns**, **aws-node** (VPC CNI), and your add-ons (**metrics-server**, **cluster-autoscaler**).

> Peek at logs to connect dots:

```bash
kubectl -n kube-system logs deploy/cluster-autoscaler | head
kubectl -n kube-system logs deploy/metrics-server | head
```

---

## 7) Sample app + HPA

Create `k8s/demo-deploy.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 1
  selector:
    matchLabels: { app: web }
  template:
    metadata:
      labels: { app: web }
    spec:
      containers:
        - name: nginx
          image: nginx:1.25
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: ClusterIP
  selector:
    app: web
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
```

Apply it:

```bash
kubectl apply -f k8s/demo-deploy.yaml
kubectl get hpa web
```

---

## 8) Generate load and watch autoscaling

Create `k8s/loadgen.yaml` (simple busybox loop):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: loadgen
spec:
  restartPolicy: Never
  containers:
    - name: loader
      image: busybox:1.36
      command: ["/bin/sh","-c"]
      args:
        - >
          i=0; while [ $i -lt 2000 ]; do
            wget -q -O- http://web.default.svc.cluster.local >/dev/null 2>&1 || true;
            i=$(($i+1));
          done; echo done; sleep 60;
```

Apply and observe:

```bash
kubectl apply -f k8s/loadgen.yaml
kubectl get hpa web -w            # watch HPA CPU -> replicas
kubectl get deploy web -w         # replicas climbing
kubectl get nodes
kubectl -n kube-system logs deploy/cluster-autoscaler -f | grep -i pending | head
```

When pods can’t be scheduled due to insufficient CPU, **Cluster Autoscaler** increases the node group size (up to `node_max`). New nodes join; pods become `Running`.

> Tip: To force node pressure, raise `maxReplicas`, or increase per-pod CPU `requests`.

---

## 9) Scale down & cleanup

* Stop the loadgen pod: `kubectl delete pod loadgen`.
* HPA will reduce replicas; Cluster Autoscaler should scale nodes **down** after its cooldown and utilization checks.
* Tear down everything when done:

```bash
terraform destroy -auto-approve
```

---

## 10) Stretch goals (optional)

* **Karpenter**: replace Cluster Autoscaler; create **NodeClass** + **Provisioner**; learn consolidation and spot handling.
* **AWS Load Balancer Controller**: expose `Service` as `LoadBalancer` and inspect ALB resources.
* **Observability**: `kube-prometheus-stack` via Helm, then graph HPA/CA metrics.
* **Node pools**: add a second node group (e.g., `t3.large` + `c6i.large`) and learn CA’s `balance-similar-node-groups`.

---

## 11) Interview review cheat sheet (quick hits)

* **CAP theorem**: in a partition, you must choose **Consistency or Availability**; distributed systems can only provide two of **C**, **A**, **P** at once (P assumed during partition).
* **Ping** uses **ICMP**; **telnet** is **TCP** only (no UDP).
* **Kubernetes core components**: API server, etcd, controller manager, scheduler; node agents: kubelet, kube-proxy; cluster add-ons include CoreDNS, CNI.
* **systemd PID** of the init process: **1**.
* **Four HTTP methods** (examples): GET, POST, PUT, DELETE (others: PATCH, HEAD, OPTIONS).
* **Minimum etcd instances (prod)**: **3** for quorum.
* **AWS data persistent after instance deletion**: **EBS** (if volume not deleted on termination) and **EBS snapshots** (S3-backed).
* **Common DNS record types**: A, AAAA, CNAME, MX, TXT, NS, SRV, PTR.

---

## 12) Troubleshooting notes

* If the `helm`/`kubernetes` providers fail on first apply, run `terraform apply` again after the EKS API becomes reachable.
* Ensure your IAM entity has permissions for EKS, IAM, VPC, and to read OIDC provider.
* Cluster Autoscaler needs the node group **tags** above; missing tags → no scale.
* `metrics-server` must be healthy for HPA to work.

Happy hacking! 🛠️

---

## Appendix: Optional Remote State (S3 + DynamoDB)

If you keep state local, **do not commit** `terraform.tfstate*` or `.terraform/`. For team use, switch to S3.

**Bootstrap (one-time):**

```bash
REGION=us-east-1
BUCKET="tfstate-eks-lab-YOUR_UNIQUE_NAME"   # must be globally unique
TABLE="tf-locks-eks-lab"

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration '{
  "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
}'
aws dynamodb create-table \
  --table-name "$TABLE" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

**backend.tf**

```hcl
terraform {
  backend "s3" {
    bucket         = "tfstate-eks-lab-YOUR_UNIQUE_NAME"
    key            = "eks-lab/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "tf-locks-eks-lab"
    encrypt        = true
  }
}
```

Initialize/migrate:

```bash
terraform init -reconfigure          # fresh
# or
terraform init -migrate-state        # if you already had local state
```

**Cleanup (if you want to delete backend later):** empty the versioned bucket then delete it; remove the DynamoDB table.

---

## GitHub Push: Repo Checklist

**.gitignore** (add at repo root):

```
.terraform/
.terraform.lock.hcl
terraform.tfstate
terraform.tfstate.backup
*.tfstate*
crash.log
override.tf
override.tf.json
*_override.tf
*_override.tf.json
terraform.tfvars
```

**README sections to include:**

* **Overview**: what the lab spins up (EKS + autoscaling + sample app).
* **Prereqs**: Terraform ≥ 1.6 (arm64 on Apple Silicon), awscli, kubectl, Helm.
* **Quickstart**: `terraform init && terraform apply`, `aws eks update-kubeconfig`, sanity checks.
* **Autoscaling Demo**: apply `k8s/demo-deploy.yaml`, run `k8s/loadgen.yaml` or `cpu-hog` snippet, watch HPA/CA.
* **Destroy**: `terraform destroy -auto-approve` (plus optional kubeconfig cleanup).
* **Optional**: S3/DynamoDB remote state (use Appendix).

> Tip: Keep the canvas as the “living runbook,” and mirror stable instructions into README so GitHub stays concise.
