#!/usr/bin/env bash
# =============================================================================
# install-kserve.sh — Install the complete KServe serving stack
# =============================================================================
#
# This script installs three components in order:
#
#   1. cert-manager  — Automated TLS certificate management for Kubernetes.
#                      KServe's webhook server needs TLS certs to validate
#                      InferenceService manifests. cert-manager generates and
#                      rotates these certs automatically.
#
#   2. Istio         — Service mesh that provides the networking layer.
#                      KServe uses Istio's ingress gateway to route external
#                      traffic to model endpoints. We install three Istio
#                      components:
#                        - istio-base: CRDs and cluster-wide resources
#                        - istiod: The control plane (config, cert distribution)
#                        - gateway: A LoadBalancer service for ingress traffic
#
#   3. KServe        — The ML model serving framework. We install:
#                        - kserve-crd: Custom Resource Definitions
#                          (InferenceService, TrainedModel, etc.)
#                        - kserve controller: Watches for InferenceService
#                          resources and creates the underlying Deployments,
#                          Services, and routing rules.
#
# Deployment Mode: RawDeployment
#   KServe supports two modes:
#     - Serverless (Knative): Auto-scaling including scale-to-zero for the
#       model pods themselves. Requires Knative Serving to be installed.
#     - RawDeployment: Uses standard Kubernetes Deployments and Services.
#       Simpler to operate, fewer moving parts, easier to debug.
#
#   We use RawDeployment because:
#     - It avoids installing Knative (significant complexity)
#     - GPU scale-to-zero is handled at the NODE level by GKE autoscaler
#       (the GPU node pool scales 0-2), not at the pod level
#     - The model pod runs continuously on its GPU node, which avoids
#       cold-start latency from model reloading (~2-3 min for 3B model)
#
# Idempotency:
#   All Helm commands use `helm upgrade --install` so this script is safe
#   to re-run. If a release already exists, it upgrades; if not, it installs.
#
#   Istio resources that may have field ownership conflicts (e.g., webhooks
#   managed by istiod/pilot-discovery) are adopted by Helm via annotation
#   before the upgrade, preventing "conflict with pilot-discovery" errors.
#
# Prerequisites:
#   - kubectl configured to point at the target cluster
#   - helm 3.0+ installed
# =============================================================================
set -euo pipefail

echo "=== Installing KServe dependencies ==="

# -----------------------------------------------------------------------------
# 1. cert-manager
# -----------------------------------------------------------------------------
# cert-manager watches for Certificate resources and automatically provisions
# TLS certs using various issuers (self-signed, Let's Encrypt, etc.).
#
# --set crds.enabled=true: Installs the CRDs (Certificate, Issuer, etc.)
#   as part of the Helm release. Without this, you'd need to apply CRDs
#   separately before installing the chart.
#
# Version v1.16.3 is pinned for reproducibility. cert-manager is very
# stable and doesn't need frequent updates.
# -----------------------------------------------------------------------------
echo "--- Installing cert-manager ---"
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update jetstack
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.3 \
  --set crds.enabled=true \
  --wait

# -----------------------------------------------------------------------------
# 2. Istio (service mesh + ingress gateway)
# -----------------------------------------------------------------------------
# Istio is installed in three stages because each Helm chart handles a
# distinct layer:
#
# a) istio-base: Installs Istio's CRDs (VirtualService, Gateway,
#    DestinationRule, etc.) and cluster-wide resources. These CRDs define
#    the API that istiod and KServe use to configure traffic routing.
#    --set defaultRevision=default: Tags this as the default Istio revision,
#    so sidecars and config use this version without explicit revision labels.
#
# b) istiod: The Istio control plane. It reads VirtualService/Gateway
#    resources and pushes Envoy proxy configuration to data-plane sidecars
#    and gateways. In our setup, KServe creates VirtualService resources
#    for each InferenceService, and istiod configures the ingress gateway
#    to route requests to the correct model pod.
#
# c) istio-ingressgateway: An Envoy-based load balancer that sits at the
#    edge of the mesh and routes external traffic into the cluster.
#    --set service.type=LoadBalancer: Creates a GCP Network Load Balancer
#    with an external IP. This is how you access model endpoints from
#    outside the cluster. For internal-only access (like OpenClaw calling
#    the model within the cluster), traffic goes directly to the KServe
#    Service without hitting the gateway.
# -----------------------------------------------------------------------------
echo "--- Installing Istio ---"
helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update
helm repo update istio

# Handle Istio webhook field ownership conflict on re-runs.
#
# When istiod (pilot-discovery) starts, it continuously reconciles the
# istiod-default-validator ValidatingWebhookConfiguration, claiming
# server-side apply field ownership. When Helm later tries to upgrade
# istio-base, it conflicts because pilot-discovery owns .failurePolicy.
#
# Transferring ownership doesn't work because istiod reclaims it
# immediately. The reliable fix is to delete the webhook before the
# upgrade — the istio-base Helm chart recreates it with Helm as owner.
# istiod will still reconcile it afterwards, but the initial install
# succeeds without conflict.
for webhook in istiod-default-validator istio-validator-istio-system; do
  if kubectl get validatingwebhookconfiguration "$webhook" &>/dev/null; then
    echo "  Deleting $webhook to avoid field ownership conflict..."
    kubectl delete validatingwebhookconfiguration "$webhook"
  fi
done

helm upgrade --install istio-base istio/base \
  --namespace istio-system \
  --create-namespace \
  --set defaultRevision=default \
  --wait

helm upgrade --install istiod istio/istiod \
  --namespace istio-system \
  --wait

helm upgrade --install istio-ingressgateway istio/gateway \
  --namespace istio-system \
  --set service.type=LoadBalancer \
  --wait

# -----------------------------------------------------------------------------
# 3. KServe
# -----------------------------------------------------------------------------
# KServe is installed in two parts:
#
# a) kserve-crd: Custom Resource Definitions only. Installed first because
#    the controller needs these CRDs to exist before it can start watching
#    for InferenceService resources.
#
# b) kserve controller: The main operator that reconciles InferenceService
#    resources. When you create an InferenceService, the controller:
#      1. Creates a Deployment running the model server (vLLM, TensorFlow, etc.)
#      2. Creates a Service for in-cluster access
#      3. Creates Istio VirtualService for external routing via the gateway
#      4. Manages readiness probes, autoscaling, canary rollouts, etc.
#
#    --set kserve.controller.deploymentMode=RawDeployment:
#      Use standard K8s Deployments instead of Knative Services.
#
#    --set kserve.controller.gateway.ingressGateway.className=istio:
#      Tells KServe to use the "istio" IngressClass for external traffic
#      routing in RawDeployment mode. KServe creates Ingress resources
#      that reference this class, and Istio's ingress controller picks
#      them up.
#
# We use OCI-based Helm charts (oci://ghcr.io/kserve/charts/*) which is
# KServe's official distribution method since v0.11+.
# Version v0.14.1 is pinned for reproducibility.
# -----------------------------------------------------------------------------
echo "--- Installing KServe ---"

# Delete KServe validating webhooks to avoid chicken-and-egg failures.
#
# The kserve-crd chart creates ValidatingWebhookConfigurations that point
# to the kserve-webhook-server-service. But during initial install (or
# re-install), the webhook server pod from the kserve chart isn't running
# yet. When Helm then tries to create ClusterServingRuntime resources, the
# API server calls the webhook, which has no endpoints, and the install
# fails. Deleting these webhooks lets Helm create the resources unvalidated.
# The KServe controller recreates the webhooks once it's running.
#
# Also deletes the ModelMesh webhook — we don't run ModelMesh (we use
# RawDeployment mode), so its certs are never provisioned and it rejects
# all ServingRuntime mutations with "unable to parse bytes as PEM block".

KSERVE_WEBHOOKS=(
  clusterservingruntime.serving.kserve.io
  inferenceservice.serving.kserve.io
  inferencegraph.serving.kserve.io
  localmodelcache.serving.kserve.io
  servingruntime.serving.kserve.io
  trainedmodel.serving.kserve.io
  modelmesh-servingruntime.serving.kserve.io
  servingruntime.modelmesh-webhook-server.default
)
for webhook in "${KSERVE_WEBHOOKS[@]}"; do
  kubectl delete validatingwebhookconfiguration "$webhook" --ignore-not-found
  kubectl delete mutatingwebhookconfiguration "$webhook" --ignore-not-found
done

# Create the Istio IngressClass resource. KServe's RawDeployment mode creates
# Kubernetes Ingress resources that reference an IngressClass. Without this
# resource, the Ingress objects would have no controller to handle them.
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: istio
spec:
  controller: istio.io/ingress-controller
EOF

helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd \
  --namespace kserve \
  --create-namespace \
  --version v0.14.1 \
  --wait

# Delete ALL KServe/ModelMesh webhooks — kserve-crd just recreated them.
# Two problems if we don't:
#   1. ModelMesh webhook has no certs (we don't run ModelMesh) and rejects all
#      ServingRuntime mutations with "unable to parse bytes as PEM block".
#   2. KServe webhooks point at kserve-webhook-server-service which has no
#      endpoints yet (the controller pod comes from the kserve chart below).
# Delete both validating AND mutating webhook configs unconditionally.
# Also do a broad sweep for any modelmesh webhooks not in the named list.
# Delete ALL KServe/ModelMesh webhooks before kserve install.
echo "  Deleting KServe webhooks before kserve install..."
for webhook in "${KSERVE_WEBHOOKS[@]}"; do
  kubectl delete validatingwebhookconfiguration "$webhook" --ignore-not-found
  kubectl delete mutatingwebhookconfiguration "$webhook" --ignore-not-found
done
# Sweep for any webhook referencing modelmesh or kserve-webhook-server.
for kind in mutatingwebhookconfigurations validatingwebhookconfigurations; do
  for wh in $(kubectl get "$kind" -o name 2>/dev/null); do
    if kubectl get "$wh" -o yaml 2>/dev/null | grep -qE "modelmesh|kserve-webhook-server"; then
      echo "  Deleting $wh..."
      kubectl delete "$wh" --ignore-not-found
    fi
  done
done

# Two-phase KServe install to solve the chicken-and-egg webhook problem:
#
# The kserve chart creates webhook configs, the controller Deployment, AND
# ClusterServingRuntime resources in one install. The webhooks intercept
# ClusterServingRuntime creation, but the webhook server (controller pod)
# isn't running yet → "no endpoints available" error.
#
# Phase 1: Let helm install fail (it creates the Deployment + Service, but
#          fails on ClusterServingRuntime). Then delete the webhooks and
#          wait for the controller pod to start.
# Phase 2: Re-run helm upgrade. The controller is now running, webhooks
#          are recreated with working endpoints, and all resources succeed.

KSERVE_HELM_ARGS=(
  --namespace kserve
  --version v0.14.1
  --set kserve.controller.deploymentMode=RawDeployment
  --set kserve.controller.gateway.ingressGateway.className=istio
  --set kserve.modelmesh.enabled=false
)

echo "  Phase 1: Installing kserve (controller Deployment)..."
if ! helm upgrade --install kserve oci://ghcr.io/kserve/charts/kserve \
    "${KSERVE_HELM_ARGS[@]}" --wait --timeout 60s 2>/dev/null; then

  echo "  Phase 1 partially installed (expected — webhook has no endpoints yet)."
  echo "  Cleaning up webhooks and waiting for controller pod..."

  # Delete all kserve/modelmesh webhooks so the controller pod can start
  # without anything blocking resource creation.
  for kind in mutatingwebhookconfigurations validatingwebhookconfigurations; do
    for wh in $(kubectl get "$kind" -o name 2>/dev/null); do
      if kubectl get "$wh" -o yaml 2>/dev/null | grep -qE "modelmesh|kserve-webhook-server"; then
        kubectl delete "$wh" --ignore-not-found
      fi
    done
  done

  # Wait for the controller pod to become ready (it provides webhook endpoints).
  echo "  Waiting for kserve-controller-manager pod..."
  kubectl wait --for=condition=Ready pod \
    -l control-plane=kserve-controller-manager \
    -n kserve --timeout=120s

  # Phase 2: Re-run helm — controller is running, webhooks will work.
  echo "  Phase 2: Completing kserve install..."
  helm upgrade --install kserve oci://ghcr.io/kserve/charts/kserve \
    "${KSERVE_HELM_ARGS[@]}" --wait
fi

echo "=== KServe installation complete ==="
echo ""
echo "Verify with:"
echo "  kubectl get pods -n cert-manager"
echo "  kubectl get pods -n istio-system"
echo "  kubectl get pods -n kserve"
