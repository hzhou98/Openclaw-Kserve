#!/usr/bin/env python3
"""Generate architecture diagram for OpenClaw + KServe on GKE."""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

fig, ax = plt.subplots(1, 1, figsize=(18, 14))
ax.set_xlim(0, 18)
ax.set_ylim(-1.0, 13.5)
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
C_OPENAI   = "#10A37F"  # OpenAI green


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
          connectionstyle="arc3,rad=0", fontsize=7.5, label_offset=0.18):
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
        ax.text(mx, my + label_offset, label, ha="center", va="center",
                fontsize=fontsize, color=color, zorder=5,
                bbox=dict(boxstyle="round,pad=0.15", fc="#FFFFFF",
                          ec="none", alpha=0.85))


# ═══════════════════════════════════════════════════════════════
# Title
# ═══════════════════════════════════════════════════════════════
ax.text(9, 13.1, "OpenClaw + KServe on GKE  —  System Architecture",
        ha="center", va="center", fontsize=16, fontweight="bold",
        color=C_TITLE)

# ═══════════════════════════════════════════════════════════════
# GCP outer box
# ═══════════════════════════════════════════════════════════════
rounded_box(0.5, 1.0, 17, 11.5, "", C_GCP, C_GCP_B, lw=2.5, alpha=0.35)
ax.text(1.2, 12.2, "Google Cloud Platform", fontsize=11,
        fontweight="bold", color=C_GCP_B, zorder=5)

# ═══════════════════════════════════════════════════════════════
# GKE Cluster box
# ═══════════════════════════════════════════════════════════════
rounded_box(1.0, 1.5, 16, 10.3, "", C_CLUSTER, C_CLUSTER_B, lw=2, alpha=0.3)
ax.text(1.7, 11.5, "GKE Cluster  (Terraform-managed)", fontsize=10,
        fontweight="bold", color=C_CLUSTER_B, zorder=5)

# ═══════════════════════════════════════════════════════════════
# System Node Pool
# ═══════════════════════════════════════════════════════════════
rounded_box(1.5, 5.0, 15, 6.1, "", C_SYS_POOL, C_SYS_B, lw=1.5, alpha=0.35)
ax.text(2.2, 10.8, "System Node Pool  (e2-standard-2, spot, 1-4 nodes)",
        fontsize=9, fontweight="bold", color="#E65100", zorder=5)

# ── cert-manager ──
rounded_box(2.0, 9.2, 3.0, 1.3, "cert-manager", C_COMP, "#78909C",
            sublabel="TLS certificate\nmanagement")

# ── Istio ──
rounded_box(5.5, 9.2, 3.0, 1.3, "Istio", C_COMP, "#1565C0",
            sublabel="istiod + Ingress\nGateway (LB)")

# ── KServe Controller ──
rounded_box(9.0, 9.2, 3.5, 1.3, "KServe Controller", C_COMP, "#2E7D32",
            sublabel="Watches InferenceService\nCreates Deployments")

# ── "Local models only" annotation ──
ax.text(14.5, 9.85, "Local models only\n(llama/qwen)", fontsize=8,
        ha="center", va="center", color="#78909C", style="italic", zorder=5,
        bbox=dict(boxstyle="round,pad=0.2", fc="#F5F5F5", ec="#BDBDBD",
                  alpha=0.9))

# ── OpenClaw Pod ──
rounded_box(2.0, 5.5, 7.0, 3.2, "", C_OPENCLAW, "#1976D2", lw=1.5, alpha=0.6)
ax.text(5.5, 8.4, "OpenClaw  (ns: openclaw)", fontsize=10,
        fontweight="bold", color="#0D47A1", ha="center", zorder=5)

rounded_box(2.3, 7.0, 2.5, 1.1, "Node.js Gateway", C_COMP, "#1976D2",
            sublabel="Port 18789", fontsize=9)
rounded_box(5.1, 7.0, 1.6, 1.1, "5Gi PVC", C_COMP, "#1976D2",
            sublabel="Chat history\nDevice pairs", fontsize=9)
rounded_box(7.0, 7.0, 1.8, 1.1, "init-skills", C_COMP, "#1976D2",
            sublabel="ClawHub\nskills (opt.)", fontsize=8)

# ── OpenClaw routing: two paths ──
# Path label inside OpenClaw box
rounded_box(2.3, 5.7, 6.4, 1.0, "", "#E3F2FD", "#1976D2", lw=0.8, alpha=0.3)
ax.text(5.5, 6.2, "LLM routing: KServe in-cluster  OR  OpenAI API (internet)",
        ha="center", va="center", fontsize=7.5, color="#1565C0", zorder=5,
        style="italic")

# ── KServe InferenceService info ──
rounded_box(9.5, 5.5, 6.5, 2.5, "", "#FFF3E0", "#EF6C00", lw=1.5, alpha=0.5)
ax.text(12.75, 7.7, "KServe InferenceService  (ns: kserve)", fontsize=10,
        fontweight="bold", color="#BF360C", ha="center", zorder=5)

rounded_box(9.8, 6.1, 3.0, 1.2, "K8s Service", C_COMP, "#EF6C00",
            sublabel="llama-3-2b-predictor\n.kserve.svc:80", fontsize=9)
rounded_box(13.1, 6.1, 2.6, 1.2, "HF Secret", C_COMP, "#EF6C00",
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
rounded_box(13.7, 2.3, 2.0, 1.1, "OpenAI API", C_COMP, C_OPENAI,
            sublabel="gpt-4o-mini\nNo GPU/KServe", fontsize=8.5)

# ═══════════════════════════════════════════════════════════════
# Browser (outside cluster)
# ═══════════════════════════════════════════════════════════════
rounded_box(0.3, -0.8, 3.0, 0.8, "Browser", C_BROWSER, "#7B1FA2",
            fontsize=11, fontweight="bold",
            sublabel="localhost:18789")

# ═══════════════════════════════════════════════════════════════
# OpenAI API (outside cluster)
# ═══════════════════════════════════════════════════════════════
rounded_box(14.5, -0.8, 3.0, 0.8, "OpenAI API", "#E8F5E9", C_OPENAI,
            fontsize=11, fontweight="bold",
            sublabel="api.openai.com")

# ═══════════════════════════════════════════════════════════════
# Arrows
# ═══════════════════════════════════════════════════════════════

# Browser → OpenClaw
arrow(1.8, 0.0, 3.5, 7.0,
      "kubectl port-forward\nWebSocket / HTTP", "#7B1FA2")

# OpenClaw → K8s Service (KServe) — local model path
arrow(9.0, 6.75, 9.8, 6.75,
      "POST /v1/chat/completions", "#1565C0")

# K8s Service → vLLM Pod
arrow(10.8, 6.1, 5.25, 4.0,
      "in-cluster DNS routing", "#EF6C00")

# KServe Controller → InferenceService
arrow(10.75, 9.2, 12.75, 8.0,
      "reconciles", C_CLUSTER_B, connectionstyle="arc3,rad=-0.3")

# cert-manager → Istio (TLS)
arrow(5.0, 9.85, 5.5, 9.85, "", "#78909C")

# OpenClaw → OpenAI API (internet path) — dashed style
ax.annotate(
    "", xy=(16.0, 0.0), xytext=(7.0, 5.5),
    arrowprops=dict(
        arrowstyle="->", color=C_OPENAI, lw=1.8,
        connectionstyle="arc3,rad=0.2",
        linestyle="dashed",
    ),
    zorder=4,
)
ax.text(12.5, 1.6, "OpenAI API mode\n(no KServe needed)", ha="center", va="center",
        fontsize=7.5, color=C_OPENAI, zorder=5, fontweight="bold",
        bbox=dict(boxstyle="round,pad=0.15", fc="#FFFFFF", ec="none", alpha=0.85))

# ═══════════════════════════════════════════════════════════════
# Deployment flow (right side annotation)
# ═══════════════════════════════════════════════════════════════

# Save
output = "/Users/hzhou98/StJude/Projects/Openclaw-Kserve/docs/architecture.png"
fig.savefig(output, dpi=180, bbox_inches="tight", facecolor=fig.get_facecolor())
plt.close()
print(f"Saved to {output}")
