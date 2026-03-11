# Operations Guide

## Cost Estimates

| Component | Spot $/hr | Spot $/month (24/7) |
|-----------|-----------|---------------------|
| GKE control plane (zonal) | $0.00 | $0.00 |
| e2-standard-2 spot (system) | ~$0.02 | ~$14.60 |
| g2-standard-4 spot (GPU host, includes L4) | ~$0.14 | ~$100.00 |
| pd-standard 80GB total | ~$0.004 | ~$3.20 |
| **Total (GPU running)** | **~$0.17** | **~$118** |
| **Total (GPU scaled to zero)** | **~$0.02** | **~$15** |

All nodes use spot instances. The GPU pool scales to zero when idle.

## Stop and Start

Use `stop.sh` and `start.sh` to pause and resume the cluster without a full teardown/redeploy cycle.

### Stopping

```bash
./stop.sh              # Stop GPU only — delete model, system pool stays (~$0.02/hr)
./stop.sh --all        # Stop everything — resize all pools to 0 nodes (~$0.00/hr)
./stop.sh --destroy    # Destroy cluster entirely via Terraform ($0.00, needs full redeploy)
```

### Restarting

```bash
./start.sh              # Redeploy model only (after stop.sh)
./start.sh --all        # Restart nodes + redeploy model (after stop.sh --all)
./start.sh --model qwen # Restart with Qwen instead of Llama
```

### Stop/start comparison

| Command | What happens | Hourly cost | Restart time |
|---------|-------------|-------------|-------------|
| `./stop.sh` | Model deleted, GPU scales to 0, system pool stays | ~$0.02 | ~5-10 min |
| `./stop.sh --all` | All node pools resized to 0, control plane stays (free) | ~$0.00 | ~5-10 min |
| `./stop.sh --destroy` | Cluster deleted entirely via Terraform | $0.00 | ~25-40 min (full deploy.sh) |

### Typical daily workflow

```bash
# Morning: start working
./start.sh                  # GPU node provisions, model loads (~5-10 min)

# Evening: done for the day
./stop.sh                   # GPU stops, saves ~$0.15/hr GPU cost

# Weekend: not using it at all
./stop.sh --all             # Everything stops, saves ~$0.17/hr

# Monday: back to work
./start.sh --all            # Nodes + model restart (~5-10 min)
```

### How stop --all works

When you run `./stop.sh --all`, the script:

1. Deletes all InferenceServices (model pods stop, GPU node drains)
2. Resizes `system-pool` to 0 nodes via `gcloud container clusters resize`
3. Resizes `gpu-pool` to 0 nodes

The GKE **control plane keeps running** (free for zonal clusters). All Kubernetes state is preserved — namespaces, secrets, Helm releases, ConfigMaps. They're stored in etcd on the control plane, not on worker nodes.

When you run `./start.sh --all`:

1. Resizes `system-pool` back to 1 node
2. Waits for the node to become Ready
3. Waits for system pods (Istio, KServe controller) to reschedule
4. Re-applies the InferenceService (GPU node scales up, model loads)
5. OpenClaw pod reschedules automatically and reconnects to the model

## Teardown

There are multiple levels of teardown depending on how much you want to remove.

### Option 1: Stop GPU costs only (keep everything else)

Remove the InferenceService so the GPU node scales to zero. The cluster, KServe, and OpenClaw stay running. You can re-apply the InferenceService later to bring the model back.

```bash
# Delete the model — GPU node pool scales to 0 within ~10 min
kubectl delete inferenceservice llama-3-2b -n kserve

# Verify GPU node is gone
kubectl get nodes -l pool=gpu
# No resources found

# Cost after this: ~$0.02/hr (system pool only)
```

To bring the model back:
```bash
kubectl apply -f kserve/llama-inferenceservice.yaml
```

### Option 2: Delete all workloads (keep the cluster)

Remove OpenClaw, the model, and KServe but keep the GKE cluster for other use.

```bash
# Delete OpenClaw
helm uninstall openclaw -n openclaw
kubectl delete namespace openclaw

# Delete model and KServe
kubectl delete inferenceservice llama-3-2b -n kserve
helm uninstall kserve -n kserve
helm uninstall kserve-crd -n kserve
kubectl delete namespace kserve

# Delete Istio
helm uninstall istio-ingressgateway -n istio-system
helm uninstall istiod -n istio-system
helm uninstall istio-base -n istio-system
kubectl delete namespace istio-system

# Delete cert-manager
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager

# If using ArgoCD:
argocd app delete openclaw-stack --cascade  # Deletes all child apps
helm uninstall argocd -n argocd
kubectl delete namespace argocd

# Cost after this: ~$0.02/hr (empty system pool)
```

### Option 3: Delete the GKE cluster (keep the GCP project)

Destroy all Terraform-managed infrastructure. This deletes the cluster, all node pools, all workloads, and all persistent disks.

```bash
cd terraform
terraform destroy
# Type "yes" when prompted

# Verify — should show no clusters
gcloud container clusters list --project=$(terraform output -raw cluster_name 2>/dev/null || cat terraform.tfvars | grep project_id | cut -d'"' -f2)

# Cost after this: $0.00/hr (nothing running)
```

To redeploy from scratch later:
```bash
./deploy.sh
```

### Option 4: Delete the entire GCP project (nuclear option)

This is the cleanest teardown — it deletes the project and **everything inside it**: the cluster, all VMs, disks, networking, IAM policies, and API configurations. Nothing survives. Billing stops immediately.

```bash
# First, check what project you're about to delete
gcloud config get-value project
# openclaw-kserve-001

# Delete the project
gcloud projects delete openclaw-kserve-001

# You will be prompted to confirm. Type the project ID again.
```

**Important details about project deletion:**

- **30-day recovery window**: GCP doesn't delete the project immediately. It enters a "pending deletion" state for 30 days, during which you can restore it:
  ```bash
  # Restore a project within the 30-day window
  gcloud projects undelete openclaw-kserve-001
  ```
  After 30 days, the project and all data are permanently destroyed.

- **Billing stops immediately**: Even though the project isn't fully deleted for 30 days, you stop being charged as soon as you run the delete command. All resources are shut down.

- **Project ID is reserved**: The globally unique project ID cannot be reused by anyone (including you) even after the project is permanently deleted. Choose a new ID if you recreate.

- **Organization-managed projects**: If the project was created under an organization, you need the `resourcemanager.projects.delete` permission on the project. Org admins may have restricted this. If denied:
  ```bash
  # Check who can delete projects in your org
  gcloud projects get-iam-policy openclaw-kserve-001 \
    --format="table(bindings.role, bindings.members)" \
    --filter="bindings.role:roles/resourcemanager.projectDeleter OR bindings.role:roles/owner"
  ```

- **Terraform state**: If you delete the project via `gcloud` instead of `terraform destroy`, Terraform's state file will be out of sync. Clean it up:
  ```bash
  # Remove stale state after manual project deletion
  cd terraform
  rm -f terraform.tfstate terraform.tfstate.backup
  ```

### Teardown comparison

| Method | What's deleted | Recovery | Time to $0 cost |
|--------|---------------|----------|-----------------|
| Delete InferenceService | Model pod + GPU node | Re-apply YAML | ~10 min |
| Helm uninstall all | All workloads | Re-run deploy.sh | ~5 min |
| `terraform destroy` | Cluster + nodes + disks | Re-run deploy.sh (~15 min) | Immediate |
| `gcloud projects delete` | Everything in the project | `gcloud projects undelete` within 30 days | Immediate |

---

[Back to main README](../README.md)
