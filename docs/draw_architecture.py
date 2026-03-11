#!/usr/bin/env python3
"""Generate architecture diagram for OpenClaw + KServe on GKE."""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

fig, ax = plt.subplots(1, 1, figsize=(18, 13))
ax.set_xlim(0, 18)
ax.set_ylim(0, 13)
ax.axis("off")
fig.patch.set_facecolor("#FAFBFC")

# ── Color palette ──
C_GCP      = "#E8F0FE"  # light blue
C_GCP_B    = "#4285F4"  # GCP blue border
C_CLUSTER  = "#F1F8E9"  # light green
C_CLUSTER_B= "#43A047"  # green border
C_SYS_POOL = "#FFF8E1"  # light amber
C_SYS_B    = "#F9A825"  # amber border
C_GPU_POOL = "#FCE4EC"  # light pink
C_GPU_B    = "#E53935"  # red border
C_COMP     = "#FFFFFF"  # white component bg
C_OPENCLAW = "#E3F2FD"  # light blue
C_VLLM     = "#FBE9E7"  # light orange
C_BROWSER  = "#EDE7F6"  # light purple
C_ARROW    = "#455A64"  # dark grey
C_TITLE    = "#1A237E"  # dark blue


def rounded_box(x, y, w, h, label, facecolor, edgecolor, lw=1.5,
                fontsize=10, fontweight="normal", alpha=1.0, sublabel=None,
                label_y_offset=0):
    """Draw a rounded rectangle with centered label."""
    box = FancyBboxPatch(
        (x, y), w, h,
        boxstyle="round,pad=0.15",
        facecolor=facecolor, edgecolor=edgecolor,
        linewidth=lw, alpha=alpha, zorder=2,
    )
    ax.add_patch(box)
    ly = y + h / 2 + label_y_offset
    if sublabel:
        ly = y + h / 2 + 0.15
    ax.text(x + w / 2, ly, label,
            ha="center", va="center", fontsize=fontsize,
            fontweight=fontweight, zorder=3, color="#212121")
    if sublabel:
        ax.text(x + w / 2, y + h / 2 - 0.22, sublabel,
                ha="center", va="center", fontsize=7.5,
                zorder=3, color="#616161", style="italic")


def arrow(x1, y1, x2, y2, label="", color=C_ARROW, style="->",
          connectionstyle="arc3,rad=0", fontsize=7.5):
    """Draw an arrow with optional label."""
    ax.annotate(
        "", xy=(x2, y2), xytext=(x1, y1),
        arrowprops=dict(
            arrowstyle=style, color=color, lw=1.8,
            connectionstyle=connectionstyle,
        ),
        zorder=4,
    )
    if label:
        mx, my = (x1 + x2) / 2, (y1 + y2) / 2
        ax.text(mx, my + 0.18, label, ha="center", va="center",
                fontsize=fontsize, color=color, zorder=5,
                bbox=dict(boxstyle="round,pad=0.15", fc="#FFFFFF",
                          ec="none", alpha=0.85))


# ═══════════════════════════════════════════════════════════════
# Title
# ═══════════════════════════════════════════════════════════════
ax.text(9, 12.6, "OpenClaw + KServe on GKE  —  System Architecture",
        ha="center", va="center", fontsize=16, fontweight="bold",
        color=C_TITLE)

# ═══════════════════════════════════════════════════════════════
# GCP outer box
# ═══════════════════════════════════════════════════════════════
rounded_box(0.5, 1.0, 17, 11.0, "", C_GCP, C_GCP_B, lw=2.5, alpha=0.35)
ax.text(1.2, 11.7, "Google Cloud Platform", fontsize=11,
        fontweight="bold", color=C_GCP_B, zorder=5)

# ═══════════════════════════════════════════════════════════════
# GKE Cluster box
# ═══════════════════════════════════════════════════════════════
rounded_box(1.0, 1.5, 16, 9.8, "", C_CLUSTER, C_CLUSTER_B, lw=2, alpha=0.3)
ax.text(1.7, 11.0, "GKE Cluster  (Terraform-managed)", fontsize=10,
        fontweight="bold", color=C_CLUSTER_B, zorder=5)

# ═══════════════════════════════════════════════════════════════
# System Node Pool
# ═══════════════════════════════════════════════════════════════
rounded_box(1.5, 5.0, 15, 5.6, "", C_SYS_POOL, C_SYS_B, lw=1.5, alpha=0.35)
ax.text(2.2, 10.3, "System Node Pool  (e2-standard-2, spot, 1-4 nodes)",
        fontsize=9, fontweight="bold", color="#E65100", zorder=5)

# ── cert-manager ──
rounded_box(2.0, 8.6, 3.0, 1.3, "cert-manager", C_COMP, "#78909C",
            sublabel="TLS certificate\nmanagement")

# ── Istio ──
rounded_box(5.5, 8.6, 3.0, 1.3, "Istio", C_COMP, "#1565C0",
            sublabel="istiod + Ingress\nGateway (LB)")

# ── KServe Controller ──
rounded_box(9.0, 8.6, 3.5, 1.3, "KServe Controller", C_COMP, "#2E7D32",
            sublabel="Watches InferenceService\nCreates Deployments")

# ── Namespaces legend (small) ──
rounded_box(13.0, 8.6, 3.0, 1.3, "Namespaces", C_COMP, "#78909C",
            sublabel="cert-manager | istio-system\nkserve | openclaw", fontsize=9)

# ── OpenClaw Pod ──
rounded_box(2.0, 5.5, 5.5, 2.5, "", C_OPENCLAW, "#1976D2", lw=1.5, alpha=0.6)
ax.text(4.75, 7.7, "OpenClaw  (ns: openclaw)", fontsize=10,
        fontweight="bold", color="#0D47A1", ha="center", zorder=5)

rounded_box(2.3, 6.2, 2.5, 1.1, "Node.js Gateway", C_COMP, "#1976D2",
            sublabel="Port 18789", fontsize=9)
rounded_box(5.1, 6.2, 2.1, 1.1, "5Gi PVC", C_COMP, "#1976D2",
            sublabel="Chat history\nDevice pairs", fontsize=9)

# ── KServe InferenceService info ──
rounded_box(8.5, 5.5, 7.5, 2.5, "", "#FFF3E0", "#EF6C00", lw=1.5, alpha=0.5)
ax.text(12.25, 7.7, "KServe InferenceService  (ns: kserve)", fontsize=10,
        fontweight="bold", color="#BF360C", ha="center", zorder=5)

rounded_box(8.8, 6.1, 3.2, 1.2, "K8s Service", C_COMP, "#EF6C00",
            sublabel="llama-3-2b-predictor\n.kserve.svc:80", fontsize=9)
rounded_box(12.3, 6.1, 3.4, 1.2, "HF Secret", C_COMP, "#EF6C00",
            sublabel="HuggingFace token\nfor model download", fontsize=9)

# ═══════════════════════════════════════════════════════════════
# GPU Node Pool
# ═══════════════════════════════════════════════════════════════
rounded_box(1.5, 1.8, 15, 2.8, "", C_GPU_POOL, C_GPU_B, lw=1.5, alpha=0.3)
ax.text(2.2, 4.3, "GPU Node Pool  (g2-standard-4 + NVIDIA L4, spot, 0-1 nodes, scales-to-zero)",
        fontsize=9, fontweight="bold", color="#B71C1C", zorder=5)

# ── vLLM Pod ──
rounded_box(2.5, 2.1, 5.5, 1.9, "", C_VLLM, "#D84315", lw=1.5, alpha=0.6)
ax.text(5.25, 3.75, "vLLM Model Pod", fontsize=10,
        fontweight="bold", color="#BF360C", ha="center", zorder=5)

rounded_box(2.8, 2.3, 2.3, 1.1, "vLLM Engine", C_COMP, "#D84315",
            sublabel="OpenAI-compat\nAPI :8080", fontsize=9)
rounded_box(5.4, 2.3, 2.3, 1.1, "NVIDIA L4", C_COMP, "#D84315",
            sublabel="24GB VRAM\nModel weights", fontsize=9)

# ── Model options ──
rounded_box(9.0, 2.1, 7.0, 1.9, "", "#E8EAF6", "#3949AB", lw=1, alpha=0.5)
ax.text(12.5, 3.75, "Model Options  (--model flag)", fontsize=10,
        fontweight="bold", color="#1A237E", ha="center", zorder=5)

rounded_box(9.3, 2.3, 2.0, 1.1, "Llama 3.2 3B", C_COMP, "#3949AB",
            sublabel="~6GB FP16\nGated (HF token)", fontsize=8.5)
rounded_box(11.5, 2.3, 2.0, 1.1, "Qwen 3.5 2B", C_COMP, "#3949AB",
            sublabel="~4GB FP16\nOpen model", fontsize=8.5)
rounded_box(13.7, 2.3, 2.0, 1.1, "OpenAI API", C_COMP, "#3949AB",
            sublabel="gpt-4o-mini\nNo GPU needed", fontsize=8.5)

# ═══════════════════════════════════════════════════════════════
# Browser (outside cluster)
# ═══════════════════════════════════════════════════════════════
rounded_box(0.3, 0.0, 3.0, 0.8, "Browser", C_BROWSER, "#7B1FA2",
            fontsize=11, fontweight="bold",
            sublabel="localhost:18789")

# ═══════════════════════════════════════════════════════════════
# Arrows
# ═══════════════════════════════════════════════════════════════

# Browser → OpenClaw
arrow(1.8, 0.8, 3.5, 6.2,
      "kubectl port-forward\nWebSocket / HTTP", "#7B1FA2")

# OpenClaw → K8s Service (KServe)
arrow(7.5, 6.75, 8.8, 6.75,
      "POST /v1/chat/completions", "#1565C0")

# K8s Service → vLLM Pod
arrow(10.0, 6.1, 5.25, 4.0,
      "in-cluster DNS routing", "#EF6C00")

# KServe Controller → InferenceService
arrow(10.75, 8.6, 12.25, 8.0,
      "reconciles", C_CLUSTER_B, connectionstyle="arc3,rad=-0.3")

# cert-manager → KServe (TLS)
arrow(5.0, 9.25, 5.5, 9.25, "", "#78909C")

# ═══════════════════════════════════════════════════════════════
# Deployment flow (right side annotation)
# ═══════════════════════════════════════════════════════════════

# Save
output = "/Users/hzhou98/StJude/Projects/Openclaw-Kserve/docs/architecture.png"
fig.savefig(output, dpi=180, bbox_inches="tight", facecolor=fig.get_facecolor())
plt.close()
print(f"Saved to {output}")
