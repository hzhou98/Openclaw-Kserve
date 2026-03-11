# ArgoCD (GitOps Deployment)

For production use, ArgoCD provides continuous GitOps delivery: push to Git → ArgoCD syncs to the cluster automatically.

## Setup

```bash
# 1. Install ArgoCD on the cluster
chmod +x argocd/install-argocd.sh
bash argocd/install-argocd.sh

# 2. Access the ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8443:443
# Open https://localhost:8443
# Login with admin / <password printed by install script>

# 3. Update repoURL in argocd/app-of-apps.yaml to YOUR Git repo
vim argocd/app-of-apps.yaml

# 4. Push this repo to Git
git init && git add . && git commit -m "Initial commit"
git remote add origin https://github.com/YOUR_USERNAME/Openclaw-Kserve.git
git push -u origin main

# 5. Bootstrap the app-of-apps
kubectl apply -f argocd/app-of-apps.yaml

# 6. Set secrets (these don't go in Git)
argocd login localhost:8443 --username admin --password '<password>' --insecure
argocd app set openclaw-model \
  --helm-set hfToken=hf_xxx \
  --helm-set gatewayToken=my-secret-token
```

## How ArgoCD Manages the Stack

ArgoCD uses the **app-of-apps pattern**: one parent Application (`openclaw-stack`) that manages child Applications:

```
openclaw-stack (app-of-apps)
  ├── cert-manager       (sync-wave: -4, installs first)
  ├── istio-base         (sync-wave: -3)
  ├── istiod             (sync-wave: -2)
  ├── istio-gateway      (sync-wave: -2)
  ├── kserve-crd         (sync-wave: -1)
  ├── kserve-controller  (sync-wave: -1)
  └── openclaw-model     (sync-wave: 0, installs last)
```

**Sync waves** control installation order (lower number = installed first). This ensures dependencies are met: cert-manager before Istio, Istio before KServe, KServe before the model.

## ArgoCD Features You Get

| Feature | What it does |
|---------|-------------|
| **Auto-sync** | Git push → cluster updates automatically |
| **Self-heal** | Manual `kubectl` changes get reverted to match Git |
| **Pruning** | Resources deleted from Git get deleted from cluster |
| **Rollback** | One-click rollback to any previous Git revision |
| **Diff view** | See exactly what changed before syncing |
| **Health checks** | Visual status of every pod, service, and deployment |

## ArgoCD File Structure

```
argocd/
├── install-argocd.sh      # Script to install ArgoCD itself
├── app-of-apps.yaml       # Parent Application (bootstrap this first)
└── apps/
    ├── cert-manager.yaml  # Child app: cert-manager Helm chart
    ├── istio.yaml         # Child app: Istio (base + istiod + gateway)
    ├── kserve.yaml        # Child app: KServe (CRDs + controller)
    └── openclaw-stack.yaml # Child app: Our custom Helm chart
```

## Day-2 Operations with ArgoCD

```bash
# Change the model — edit helm-chart/values.yaml, commit, push:
#   ArgoCD detects the change and syncs automatically

# Scale down GPU (stop paying for it):
#   Delete the InferenceService from Git → ArgoCD removes it → GPU scales to 0

# View sync status:
argocd app list
argocd app get openclaw-stack

# Force sync (don't wait for poll interval):
argocd app sync openclaw-stack

# View diff before syncing:
argocd app diff openclaw-stack
```

---

[Back to main README](../README.md)
