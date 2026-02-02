# OpenShift Filesystem MCP

<!-- SPDX-License-Identifier: Apache-2.0 -->

Model Context Protocol (MCP) server that exposes **read-only** access to OpenShift node host paths (`/etc`, `/sys`, `/proc`) over HTTP/SSE. Intended for use with AI assistants and tools that speak MCP and need to inspect host-level configuration and system state on an OpenShift cluster.

## Overview

- **MCP server**: [@modelcontextprotocol/server-filesystem](https://github.com/modelcontextprotocol/servers) runs inside a container with host paths mounted at `/host/etc`, `/host/sys`, `/host/proc`.
- **Transport**: [mcp-proxy](https://www.npmjs.com/package/mcp-proxy) bridges the stdio-based MCP server to HTTP/SSE so it can be reached via an OpenShift Route.
- **Image**: Red Hat UBI9 Node.js 22; built from the included Containerfile.

## Prerequisites

- OpenShift cluster (or Kubernetes with host path mounts and appropriate security context).
- `kubectl` and `oc` in your path.
- Container tool: **podman** (default) or **docker**.
- For building from the Containerfile: access to `registry.redhat.io` (e.g. via OpenShift pull-secret; see [Registry credentials](#registry-credentials)).

## Quick Start

1. **Create and grant the custom read-only SCC (once per cluster)**  
   The deployment uses a custom SCC `hostpath-readonly` (similar to `hostmount-anyuid` but requires read-only root filesystem). Create it, then grant it to the ServiceAccount:

   ```bash
   make apply-scc
   make grant-scc
   ```

2. **Build, push, and deploy**  
   Replace `quay.io/myuser/openshift-filesystem-mcp` with your image repo:

   ```bash
   make container-build container-push deploy IMG=quay.io/myuser/openshift-filesystem-mcp:latest
   ```

3. **Get the MCP URL**  
   After deploy, the Route hostname is shown by:

   ```bash
   oc get route openshift-filesystem-mcp -n openshift-filesystem-mcp -o jsonpath='{.spec.host}'
   ```

   Use `https://<route-host>` (or `http://` if edge termination allows) as the MCP server URL in your client (e.g. Cursor, Claude Desktop).

### OpenShift Lightspeed (OLS)

To use this MCP server with OpenShift Lightspeed, add it under `mcpServers` in your OLS configuration (streamable HTTP on `/mcp`):

```yaml
mcpServers:
  - name: openshift-filesystem-mcp
    streamableHTTP:
      url: http://openshift-filesystem-mcp.openshift-filesystem-mcp.svc.cluster.local:8080/mcp
      timeout: 60
      sseReadTimeout: 0
      enableSSE: false
```

- **In-cluster URL**: Use the above when OLS runs in the same cluster (e.g. in the same or another namespace). The service is `openshift-filesystem-mcp` in namespace `openshift-filesystem-mcp`, port 8080.
- **Via Route**: If OLS reaches the cluster via the OpenShift Route, set `url` to `https://<route-host>/mcp` (get the host with `oc get route openshift-filesystem-mcp -n openshift-filesystem-mcp -o jsonpath='{.spec.host}'`).
- **Feature gate**: MCP server support may need to be enabled in your OLSConfig via the `MCPServer` feature gate:

  ```yaml
  spec:
    featureGates:
      - MCPServer
  ```

## Make Targets

| Target | Description |
|--------|-------------|
| `container-build` | Build the container image (default: podman, `linux/amd64`) |
| `container-push` | Push the image to the registry |
| `deploy` | Deploy to OpenShift with Kustomize (sets image from `IMG`) |
| `undeploy` | Remove the deployment from the cluster |
| `deploy-local` | Build and run the container locally with host `/etc`, `/sys`, `/proc` mounted read-only |
| `undeploy-local` | Stop the locally running MCP server container (use same `IMG` as for `deploy-local`) |
| `deploy-local-dirs` | Create dummy content in `.local-mcp-host/` for testing (used automatically by `deploy-local` on macOS) |
| `apply-scc` | Create the custom `hostpath-readonly` SCC in the cluster (cluster-admin, once) |
| `grant-scc` | Grant `hostpath-readonly` SCC to the ServiceAccount |
| `setup-registry-credentials` | Create `registry-credentials` from cluster pull-secret (for UBI base image) |
| `lint` | Run all linters (yamllint, hadolint, mdlint) |
| `yamllint` | Lint YAML files (config: `.yamllint.yaml`) |
| `hadolint` | Lint the Containerfile |
| `mdlint` | Lint Markdown files (config: `.pymarkdownlnt.json`) |
| `help` | Show all targets and variables |

### Variables

- **IMG** — Container image (default: `quay.io/$(USER)/openshift-filesystem-mcp:$(VERSION)`).
- **CONTAINER_ENGINE** — `podman` (default) or `docker`.
- **PLATFORM** — Build platform (default: `linux/amd64`).
- **VERSION** — Image tag (default: `git describe` or `latest`).

### Example workflow

```bash
# One-time: create SCC, grant to ServiceAccount, and (if needed) registry credentials
make apply-scc
make grant-scc
make setup-registry-credentials   # if base image pull fails

# Build, push, deploy
make container-build container-push deploy IMG=quay.io/myuser/openshift-filesystem-mcp:v1.0.0
```

## Verifying local deployment

After running `make deploy-local-dirs` and `make deploy-local`, the MCP server listens at **<http://localhost:8080>**. Use these steps to confirm it is working.

### 1. Check the container is running

In another terminal (the one that ran `make deploy-local` keeps the container in the foreground):

```bash
# With podman (default); use the image name you passed to IMG (e.g. openshift-filesystem-mcp:local)
podman ps

# Or with docker
docker ps
```

You should see one running container with port `8080` mapped (look for `openshift-filesystem-mcp` or your `IMG` name).

### 2. Check the HTTP endpoint responds

The proxy exposes `/sse` (SSE) and `/mcp` (streamable HTTP). A simple request should get a response (status or body depends on the proxy):

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/sse
# Expect a numeric HTTP status (e.g. 200 or 404); non-empty means the server is up
```

```bash
curl -s -i http://localhost:8080/sse
# Shows headers and start of SSE stream; confirms the MCP proxy is serving
```

### 3. Use an MCP client to list and read files

Configure your MCP client with the server URL **<http://localhost:8080>** (or **<http://localhost:8080/sse>** if the client expects an SSE path). Then use the client’s filesystem tools to:

- **List directories**: e.g. `/host/proc`, `/host/sys`, `/host/etc`
- **Read files**: e.g. `/host/proc/version`, `/host/proc/cpuinfo`, `/host/sys/kernel/version`

**In Cursor**: See [Configuring Cursor](#configuring-cursor) below.

**With MCP Inspector** (optional CLI-style check):

```bash
npx @modelcontextprotocol/inspector
```

In the inspector, connect with transport **HTTP/SSE** and URL `http://localhost:8080/sse`. Use the “Filesystem” tools to list and read under `/host/proc`, `/host/sys`, and `/host/etc`.

### 4. Sanity-check the dummy content (macOS)

On macOS, `deploy-local` uses dummy content from `.local-mcp-host/` for `/host/sys` and `/host/proc`. After connecting with an MCP client, reading `/host/proc/version` should return a line like:

`Linux version 5.0.0-dummy (local-mcp-host) #1 SMP ...`

and `/host/sys/kernel/version` should contain `local-mcp-host`. That confirms the server is serving the staged files correctly.

## Configuring Cursor

To use the MCP server in Cursor (with `make deploy-local` running), add the server via **MCP settings** or a project-level config file.

### Option 1: UI (Settings)

1. Open **Cursor Settings** (⌘, on macOS, Ctrl+, on Windows/Linux).
2. Search for **MCP** or go to **Features → MCP**.
3. Click **Add new MCP server** (or edit the config file link).
4. Add a remote server with:
   - **Name**: e.g. `openshift-filesystem-mcp`
   - **URL**: `http://localhost:8080/sse` (SSE) or `http://localhost:8080/mcp` (Streamable HTTP)

Save and ensure the server is enabled. Start the server with `make deploy-local` in a terminal before using it in chat.

### Option 2: Project config file

Create or edit `.cursor/mcp.json` in this project:

```json
{
  "mcpServers": {
    "openshift-filesystem-mcp": {
      "url": "http://localhost:8080/sse"
    }
  }
}
```

Cursor loads project MCP config from `.cursor/mcp.json`. Use **<http://localhost:8080/sse>** for SSE or **<http://localhost:8080/mcp>** for Streamable HTTP. The server must be running (`make deploy-local`) when you use it.

### Using the server in chat

Once configured, the MCP server appears under **Available Tools** in chat. You can ask the AI to:

- “List the contents of /host/proc”
- “Read /host/proc/version”
- “What’s in /host/sys/kernel?”
- “Read /host/etc/hosts” (or other files under `/host/etc`)

The AI will use the filesystem tools provided by the server to list and read under `/host/etc`, `/host/sys`, and `/host/proc`.

## CI (GitHub Actions)

Two workflows run on every **push to `main`** and on every **pull request targeting `main`**:

| Workflow | Description |
|----------|-------------|
| **Lint** | Runs `make lint` (yamllint, hadolint, mdlint). Uses a Python venv and dependencies from `requirements.txt`. |
| **Container build** | Runs `make container-build` with Docker to verify the image builds. Does not push to a registry. |

Config: [`.github/workflows/lint.yaml`](.github/workflows/lint.yaml), [`.github/workflows/container-build.yaml`](.github/workflows/container-build.yaml).

## Registry credentials

The Containerfile uses `registry.redhat.io/ubi9/nodejs-22`. If your cluster can pull that image via the global pull-secret, no extra step is needed. Otherwise, create a secret in the deployment namespace from the OpenShift pull-secret and configure the deployment to use it:

```bash
make setup-registry-credentials
```

Then ensure the Deployment’s `imagePullSecrets` (or default service account) references `registry-credentials` if required by your setup.

## Security

- **No write access to the host.** Host paths are mounted **read-only** (`readOnly: true`). The pod runs as non-root (`runAsUser: 1001`) with a read-only root filesystem; the only writable area is an in-memory `/tmp` (emptyDir).
- The deployment uses a custom **hostpath-readonly** SCC (see `deploy/scc-hostpath-readonly.yaml`), which allows hostPath volumes but requires read-only root filesystem; only this ServiceAccount is granted that SCC. Restrict who can create or use this deployment and namespace.
- The Route uses edge TLS; treat the MCP endpoint as sensitive and limit access (network policies, auth, or cluster visibility) as appropriate for your environment.

## Project layout

```text
.
├── .github/workflows/
│   ├── lint.yaml              # CI: make lint on push/PR to main
│   └── container-build.yaml   # CI: make container-build on push/PR to main
├── .pymarkdownlnt.json        # Markdown linter config
├── .yamllint.yaml             # YAML linter config
├── Containerfile              # UBI9 Node.js 22 + mcp-proxy + server-filesystem
├── Makefile                   # Build, push, deploy, lint, apply-scc, grant-scc, help
├── README.md
├── requirements.txt           # Linter deps (yamllint, hadolint, pymarkdownlnt)
└── deploy/
    ├── kustomization.yaml
    ├── namespace.yaml
    ├── scc-hostpath-readonly.yaml   # Custom SCC for read-only host path mounts
    ├── deployment.yaml              # Pod with hostPath volumes for /etc, /sys, /proc
    ├── service.yaml
    ├── route.yaml                   # OpenShift Route for HTTP/SSE
    └── serviceaccount.yaml
```

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for the full text.
