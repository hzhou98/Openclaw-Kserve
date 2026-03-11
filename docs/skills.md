# Skills Configuration

OpenClaw supports installable plugins called **skills** from [ClawHub](https://clawhub.com). Skills extend the agent with new capabilities such as weather lookups, web search, calendar integration, and more.

## Overview

Skills configuration lives in a **separate composable file** — [`openclaw/values-skills.yaml`](../openclaw/values-skills.yaml) — that can be layered on top of any model config. This avoids duplicating the skills init container across every model values file.

```
openclaw/
├── values.yaml              # Llama 3.2 3B model config
├── values-qwen.yaml         # Qwen 3.5 2B model config
├── values-openai.yaml       # OpenAI API model config
└── values-skills.yaml       # Skills overlay (compose with any model file)
```

Helm deep-merges multiple `-f` files left-to-right, so `values-skills.yaml` adds the `init-skills` init container and persistence mounts on top of whichever model file you choose.

On every pod startup the `init-skills` init container:

1. Creates `/home/node/.openclaw/workspace/skills/` on the persistent volume (if it doesn't exist).
2. Iterates over the skill list and runs `npx -y clawhub install <skill> --no-input` for each.
3. Skips skills that are already installed (checks for the `skills/<name>` directory).
4. Retries failed installs up to 6 times with exponential backoff and jitter.

Because skills are stored on the PVC they persist across pod restarts without re-downloading.

## Usage

### Via deploy.sh (recommended for full deployments)

Use the `--skills` flag to automatically apply `values-skills.yaml`:

```bash
./deploy.sh --model llama --skills   # Llama + skills
./deploy.sh --model qwen --skills    # Qwen + skills
./deploy.sh --model openai --skills  # OpenAI + skills
```

### Via install-openclaw.sh (for OpenClaw-only updates)

Pass multiple `--values` flags — Helm deep-merges them left-to-right:

```bash
# Llama + skills
bash openclaw/install-openclaw.sh --values values.yaml --values values-skills.yaml

# Qwen + skills
bash openclaw/install-openclaw.sh --values values-qwen.yaml --values values-skills.yaml

# OpenAI + skills
bash openclaw/install-openclaw.sh --values values-openai.yaml --values values-skills.yaml
```

### Via Helm directly

```bash
helm upgrade openclaw openclaw/openclaw -n openclaw \
  -f openclaw/values.yaml -f openclaw/values-skills.yaml
```

## Adding a skill

1. Browse available skills at [clawhub.com](https://clawhub.com) and note the skill slug (e.g., `weather`, `gog`, `web-search`).

2. Edit `openclaw/values-skills.yaml` and add the slug to the `for skill in ...` loop:

   ```yaml
   # ── Add skill slugs here ──
   for skill in weather gog web-search; do
     install_skill "$skill" || true
   done
   ```

3. Redeploy OpenClaw (with both files):

   ```bash
   bash openclaw/install-openclaw.sh --values values.yaml --values values-skills.yaml
   ```

4. Verify the skill was installed:

   ```bash
   kubectl exec -n openclaw deployment/openclaw -c main -- ls /home/node/.openclaw/workspace/skills/
   ```

## Removing a skill

1. Remove the slug from the `for skill in ...` line in `openclaw/values-skills.yaml`.

2. Delete the skill directory from the PVC:

   ```bash
   kubectl exec -n openclaw deployment/openclaw -c main -- rm -rf /home/node/.openclaw/workspace/skills/<skill-name>
   ```

3. Restart the pod to pick up the change:

   ```bash
   kubectl rollout restart deployment/openclaw -n openclaw
   ```

## Deploying without skills

Simply omit `values-skills.yaml` from the install command:

```bash
# Model only, no skills
bash openclaw/install-openclaw.sh --values values.yaml
```

## Listing installed skills

```bash
kubectl exec -n openclaw deployment/openclaw -c main -- ls /home/node/.openclaw/workspace/skills/
```

## Checking init-skills logs

If a skill fails to install, check the init container logs:

```bash
kubectl logs -n openclaw deployment/openclaw -c init-skills
```

## Runtime dependencies

Some skills require runtimes that are not included in the base OpenClaw image (e.g., Python, Go). Since all containers run with a **read-only root filesystem** as non-root (UID 1000), you cannot install packages to system paths like `/usr/local/bin`. Instead, install them to the PVC so they persist across restarts.

Add runtime installs to the `init-skills` command in `values-skills.yaml` **before** the skill installation loop.

### Python (via uv)

```yaml
command:
  - sh
  - -c
  - |
    log() { echo "[$(date -Iseconds)] [init-skills] $*"; }

    # ── Install uv (Python package manager) ──
    mkdir -p /home/node/.openclaw/bin
    if [ ! -f /home/node/.openclaw/bin/uv ]; then
      log "Installing uv..."
      curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/home/node/.openclaw/bin sh
    fi

    # ... rest of skill installation ...
```

Then expose `uv` to the main container by adding `PATH` to your model values file:

```yaml
app-template:
  controllers:
    main:
      containers:
        main:
          env:
            PATH: /home/node/.openclaw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

### pnpm (for Node.js interfaces like MS Teams)

```yaml
command:
  - sh
  - -c
  - |
    log() { echo "[$(date -Iseconds)] [init-skills] $*"; }

    # ── Install pnpm ──
    PNPM_HOME=/home/node/.openclaw/pnpm
    mkdir -p "$PNPM_HOME"
    if [ ! -f "$PNPM_HOME/pnpm" ]; then
      log "Installing pnpm..."
      curl -fsSL https://get.pnpm.io/install.sh | env PNPM_HOME="$PNPM_HOME" SHELL=/bin/sh sh -
    fi
    export PATH="$PNPM_HOME:$PATH"

    # Install packages
    cd /home/node/.openclaw
    pnpm install <your-package> --store-dir /home/node/.openclaw/.pnpm-store

    # ... rest of skill installation ...
```

Then expose pnpm to the main container:

```yaml
app-template:
  controllers:
    main:
      containers:
        main:
          env:
            PATH: /home/node/.openclaw/pnpm:/home/node/.openclaw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            PNPM_HOME: /home/node/.openclaw/pnpm
            PNPM_STORE_DIR: /home/node/.openclaw/.pnpm-store
```

## Full example with skills + Python runtime

```yaml
# values-skills.yaml (customized with uv + multiple skills)
app-template:
  controllers:
    main:
      initContainers:
        init-skills:
          image:
            repository: ghcr.io/openclaw/openclaw
            tag: "{{ .Values.openclawVersion }}"
          command:
            - sh
            - -c
            - |
              log() { echo "[$(date -Iseconds)] [init-skills] $*"; }
              log "Starting skills initialization"

              # ── Runtime: uv for Python skills ──
              mkdir -p /home/node/.openclaw/bin
              if [ ! -f /home/node/.openclaw/bin/uv ]; then
                log "Installing uv..."
                curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/home/node/.openclaw/bin sh
              fi

              # ── Skill installation ──
              mkdir -p /home/node/.openclaw/workspace/skills
              cd /home/node/.openclaw/workspace
              install_skill() {
                skill="$1"
                SKILL_NAME="$(basename "$skill")"
                if [ -z "$skill" ]; then return 0; fi
                if [ -d "skills/$SKILL_NAME" ]; then
                  log "Skill already installed: $skill"
                  return 0
                fi
                log "Installing skill: $skill"
                attempts=6; delay=5
                for i in $(seq 1 "$attempts"); do
                  if npx -y clawhub install "$skill" --no-input; then
                    log "Installed skill: $skill"
                    return 0
                  fi
                  jitter=$((RANDOM % 5))
                  if [ "$i" -lt "$attempts" ]; then
                    log "WARNING: Failed to install skill: $skill (attempt $i/$attempts). Retrying in $((delay + jitter))s..."
                    sleep $((delay + jitter))
                    delay=$((delay * 2))
                  fi
                done
                log "WARNING: Failed to install skill after $attempts attempts: $skill"
                return 1
              }

              for skill in weather gog web-search; do
                install_skill "$skill" || true
              done

              log "Skills initialization complete"
          env:
            HOME: /tmp
            NPM_CONFIG_CACHE: /tmp/.npm
          securityContext:
            runAsUser: 1000
            runAsGroup: 1000
            runAsNonRoot: true
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL

  persistence:
    data:
      advancedMounts:
        main:
          init-config:
            - path: /home/node/.openclaw
          init-skills:
            - path: /home/node/.openclaw
          main:
            - path: /home/node/.openclaw
    tmp:
      enabled: true
      type: emptyDir
      advancedMounts:
        main:
          init-config:
            - path: /tmp
          init-skills:
            - path: /tmp
          main:
            - path: /tmp
```

Deploy with:

```bash
bash openclaw/install-openclaw.sh --values values.yaml --values values-skills.yaml
```

## Reference

- [ClawHub](https://clawhub.com) — Skill marketplace
- [Upstream chart README — Skills section](https://github.com/serhanekicii/openclaw-helm/blob/main/charts/openclaw/README.md#skills)
- [Upstream chart README — Runtime Dependencies](https://github.com/serhanekicii/openclaw-helm/blob/main/charts/openclaw/README.md#runtime-dependencies)
