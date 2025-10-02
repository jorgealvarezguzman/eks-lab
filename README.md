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

---

## 13) Envoy Gateway Lab — Edge Proxy, Rate Limiting & HPA

Use **Envoy** as a simple edge proxy in front of the `web` service to learn routing, retries, circuit breaking, and rate limiting. This adds a `LoadBalancer` Service (NLB) and an HPA for Envoy.

### What you’ll learn

* Route external traffic through Envoy → `web` Service
* Apply **local rate-limiting** (429s under bursts) and **retries/circuit breaking**
* Autoscale Envoy via **HPA**; see **Cluster Autoscaler** add nodes if needed

### File layout (new)

```
./k8s/envoy/
  ├─ namespace.yaml
  ├─ configmap.yaml       # Envoy static config
  ├─ deploy.yaml          # Envoy Deployment
  ├─ service.yaml         # NLB Service
  └─ hpa.yaml             # HPA for Envoy
```

### Apply & test

```bash
# apply
kubectl apply -f k8s/envoy/namespace.yaml
kubectl apply -f k8s/envoy/configmap.yaml
kubectl apply -f k8s/envoy/deploy.yaml
kubectl apply -f k8s/envoy/service.yaml
kubectl apply -f k8s/envoy/hpa.yaml

# get external endpoint and test
LB=$(kubectl get svc -n envoy envoy-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -I http://$LB/

# burst to trigger 429s (rate limit is 5 rps per Envoy pod)
seq 60 | xargs -n1 -P20 -I{} curl -s -o /dev/null -w "%{http_code}
" http://$LB/ | sort | uniq -c

# inspect Envoy admin (optional)
kubectl -n envoy port-forward deploy/envoy-gateway 9901:9901 &
curl -s localhost:9901/stats/prometheus | grep -E 'local_rate|upstream_rq_[0-9]{3}'
```

### Drive Envoy HPA

```bash
# temporary: relax limiter if needed (increase tokens in configmap), then rollout restart
kubectl -n envoy rollout restart deploy/envoy-gateway

# generate load from inside the cluster
kubectl apply -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: envoy-load
  namespace: envoy
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: fortio
        image: fortio/fortio:latest_release
        args: ["load","-c","40","-qps","0","-t","5m","http://envoy-gateway.envoy.svc.cluster.local/"]
YAML

kubectl get hpa -n envoy -w
kubectl -n envoy get deploy envoy-gateway -w
kubectl top pods -n envoy
```

### Troubleshooting

* **503 from Envoy** → `kubectl get endpoints web`; ensure `web` Service exists and a `web` pod is `READY 1/1`.
* **Envoy CrashLoopBackOff** → ensure **router filter is last** in `http_filters`.
* **HPA shows `<unknown>`** → make sure `metrics-server` is running and Envoy has CPU **requests**.
* **Rate limit not triggering** → set `replicas: 1` or lower tokens; remember the bucket is per Envoy pod.

### Cleanup

```bash
kubectl delete ns envoy
# (or individually delete the Job/HPA/Service/Deploy/ConfigMap)
```

---

## 14) Lab A — Amazon MSK (Kafka) with EKS Producer/Consumer

### What you’ll learn

* Provision a secure **Amazon MSK** cluster in the same VPC as EKS.
* Authenticate with **SASL/SCRAM** over TLS from Kubernetes pods.
* Create a Kafka **topic**, **produce** messages, and **consume** them from EKS.

### Prereqs / assumptions

* You’ve already deployed the base EKS/VPC from this lab.
* Terraform code for MSK is added (e.g., `msk.tf`) and includes:

  * **3-broker** MSK cluster (any instance type; example uses `kafka.m5.large`).
  * **Security Group** allowing broker port from the **EKS node SG**.
  * A **Secrets Manager** secret that starts with `AmazonMSK_` and is encrypted with a **customer-managed KMS key (CMK)**.
  * SCRAM association wired to the MSK cluster.
* Variables:

  * `kafka_scram_password` set in `terraform.tfvars` (any strong string).

> **Ports recap**
>
> * `9096`: SASL/SCRAM over TLS (used in this lab)
> * `9094`: TLS (no SASL)
> * `9098`: IAM auth (not used here)

### Files (you commit these)

```
terraform/
  msk.tf                          # MSK cluster, SG rule, KMS key, secret, SCRAM assoc

k8s/msk/
  secret.yaml                     # username/password for SCRAM
  configmap.yaml                  # bootstrap servers
  topic-job.yaml                  # creates topic 'demo'
  producer-job.yaml               # sends messages to 'demo'
  consumer-pod.yaml               # reads messages from 'demo'
```

### Step 1 — Provision MSK

```bash
terraform apply
```

After apply:

```bash
terraform output -raw msk_bootstrap_sasl
# copy this value into k8s/msk/configmap.yaml (bootstrap) before applying k8s manifests
```

### Step 2 — Deploy client bits on EKS

Apply the Kubernetes manifests in order:

```bash
kubectl apply -f k8s/msk/secret.yaml
kubectl apply -f k8s/msk/configmap.yaml
kubectl apply -f k8s/msk/topic-job.yaml
kubectl logs job/kafka-create-topic
```

You should see the topic creation succeed (or “already exists”).

### Step 3 — Produce & consume

```bash
kubectl apply -f k8s/msk/producer-job.yaml
kubectl logs job/kafka-produce

kubectl apply -f k8s/msk/consumer-pod.yaml
kubectl logs pod/kcat-consumer
```

You should see the produced messages in the consumer logs.

### Troubleshooting

* **Secret association error** like *“encrypted with the default key”*: your SCRAM secret must use a **CMK** (not the default AWS-managed key). Recreate the secret using your KMS key and re-associate.
* **Auth failures** from clients: confirm the **bootstrap** string ends with `:9096`, and the **username/password** in the k8s Secret match the Secrets Manager value.
* **Connectivity timeouts**: ensure the brokers’ **Security Group** allows TCP **9096** **from the EKS node SG** (not from 0.0.0.0/0), and that you’re using **private subnets** reachable by the nodes.
* **Job immutability** errors when you change images/commands: delete the Job and re-apply (`kubectl delete job … && kubectl apply -f …`) or use `kubectl replace --force`.
* **Kubeconfig stale** (NXDOMAIN on EKS endpoint): re-run `aws eks update-kubeconfig …` or rebuild kubeconfig as in the base lab.

### Observability (optional)

* **MSK**: enable enhanced monitoring and/or broker logs to CloudWatch (if included in your Terraform).
* **Clients**: view k8s Job/Pod logs for the topic creation, producer, and consumer.

### Cleanup

```bash
# Kubernetes
kubectl delete -f k8s/msk/consumer-pod.yaml --ignore-not-found
kubectl delete -f k8s/msk/producer-job.yaml --ignore-not-found
kubectl delete -f k8s/msk/topic-job.yaml --ignore-not-found
kubectl delete -f k8s/msk/secret.yaml -f k8s/msk/configmap.yaml --ignore-not-found

# Terraform (only if you want to remove MSK)
terraform destroy -target=aws_msk_scram_secret_association.scram \
                  -target=aws_msk_cluster.this \
                  -target=aws_secretsmanager_secret.* \
                  -target=aws_kms_key.msk_scram \
                  -auto-approve
```

### Costs

* MSK brokers run 24/7; **3× brokers** plus storage will incur cost.
* This lab does **not** use MSK Connect or extra NAT/LB resources beyond your base cluster.

> Next step (Lab B idea): use **MSK Connect S3 Sink** to land topic data in S3 and read it with **Databricks**.
