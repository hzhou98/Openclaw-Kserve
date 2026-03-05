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
# Each `helm install` uses --wait, which blocks until all pods in that
# release are Running/Ready. This ensures each component is fully operational
# before the next one starts (cert-manager must be ready before KServe, etc.).
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
helm install cert-manager jetstack/cert-manager \
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

helm install istio-base istio/base \
  --namespace istio-system \
  --create-namespace \
  --set defaultRevision=default \
  --wait

helm install istiod istio/istiod \
  --namespace istio-system \
  --wait

helm install istio-ingressgateway istio/gateway \
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
#    --set kserve.controller.gateway.ingressGateway=istio-system/istio-ingressgateway:
#      Tells KServe which Istio gateway to use for external traffic routing.
#      Format is <namespace>/<gateway-name>.
#
# We use OCI-based Helm charts (oci://ghcr.io/kserve/charts/*) which is
# KServe's official distribution method since v0.11+.
# Version v0.14.1 is pinned for reproducibility.
# -----------------------------------------------------------------------------
echo "--- Installing KServe ---"
helm install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd \
  --namespace kserve \
  --create-namespace \
  --version v0.14.1 \
  --wait

helm install kserve oci://ghcr.io/kserve/charts/kserve \
  --namespace kserve \
  --version v0.14.1 \
  --set kserve.controller.deploymentMode=RawDeployment \
  --set kserve.controller.gateway.ingressGateway=istio-system/istio-ingressgateway \
  --wait

echo "=== KServe installation complete ==="
echo ""
echo "Verify with:"
echo "  kubectl get pods -n cert-manager"
echo "  kubectl get pods -n istio-system"
echo "  kubectl get pods -n kserve"
