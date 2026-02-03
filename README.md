# OpenShift Filesystem MCP

<!-- SPDX-License-Identifier: Apache-2.0 -->

Model Context Protocol (MCP) server that exposes **read-only** access to OpenShift node host paths (`/etc`, `/sys`, `/proc`, `/usr`) over HTTP/SSE. Intended for use with AI assistants and tools that speak MCP and need to inspect host-level configuration and system state on an OpenShift cluster.

## Overview

- **MCP server**: [@modelcontextprotocol/server-filesystem](https://github.com/modelcontextprotocol/servers) runs inside a Node.js container with host paths mounted at `/host/etc`, `/host/sys`, `/host/proc`, `/host/usr`.
- **Two-container architecture**:
  - **Backend** (Node.js): [mcp-proxy](https://www.npmjs.com/package/mcp-proxy) + server-filesystem — stdio-to-HTTP bridge on port 8081.
  - **Proxy**: MCP proxy with transforms (uses [FastMCP](https://gofastmcp.com)) — applies tool description overrides from YAML and hides write tools; proxies to backend; exposes HTTP on port 8080 for clients.
- **Images**: UBI9 Node.js 22 (backend), UBI9 Python 3.12 (proxy); built from `backend/Containerfile` and `proxy/Containerfile`.

## Prerequisites

- OpenShift cluster (or Kubernetes with host path mounts and appropriate security context).
- `kubectl` and `oc` in your path.
- Container tool: **podman** (default) or **docker**.
- For building from the Containerfiles: access to `registry.access.redhat.com` (UBI base images; see [Registry credentials](#registry-credentials) if pull fails).

## Quick Start

1. **Create and grant the custom read-only SCC (once per cluster)**  
   The deployment uses a custom SCC `hostpath-readonly` (similar to `hostmount-anyuid` but requires read-only root filesystem). Create it, then grant it to the ServiceAccount:

   ```bash
   make apply-scc
   make grant-scc
   ```

2. **Build, push, and deploy**  
   Builds both images; override `QUAY_WORKSPACE` or `IMG_BACKEND`/`IMG_PROXY` as needed:

   ```bash
   make container-build container-push deploy
   ```

3. **Get the MCP URL**  
   After deploy, the Route hostname is shown by:

   ```bash
   oc get route openshift-filesystem-mcp -n openshift-filesystem-mcp -o jsonpath='{.spec.host}'
   ```

   Use `https://<route-host>` (or `http://` if edge termination allows) as the MCP server URL in your client (e.g. Cursor, Claude Desktop).

### OpenShift Lightspeed (OLS)

To use this MCP server with OpenShift Lightspeed, add it under `spec.mcpServers` in your **OLSConfig** custom resource (streamable HTTP on `/mcp`). Edit the cluster OLSConfig with `oc edit olsconfig cluster` and add the following under `spec` (alongside your existing `llm`, `ols`, etc.):

```yaml
spec:
  featureGates:
    - MCPServer
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
- **Feature gate**: The `MCPServer` feature gate (shown above under `spec.featureGates`) must be enabled for MCP servers to be used.

## Make Targets

| Target | Description |
|--------|-------------|
| `container-build` | Build both container images (backend + proxy) |
| `container-push` | Push both images to the registry |
| `deploy` | Deploy to OpenShift with Kustomize (sets both images) |
| `undeploy` | Remove the deployment from the cluster |
| `deploy-local` | Build and run Node.js backend locally (no proxy; raw tools, host paths read-only) |
| `undeploy-local` | Stop the locally running MCP server container (if run in background) |
| `deploy-local-dirs` | Create dummy content in `.local-mcp-host/` for testing (used automatically by `deploy-local` on macOS) |
| `apply-scc` | Create the custom `hostpath-readonly` SCC in the cluster (cluster-admin, once) |
| `grant-scc` | Grant `hostpath-readonly` SCC to the ServiceAccount |
| `setup-registry-credentials` | Create `registry-credentials` from cluster pull-secret (if image pull fails) |
| `lint` | Run all linters (yamllint, hadolint, mdlint) |
| `yamllint` | Lint YAML files (config: `.yamllint.yaml`) |
| `hadolint` | Lint Containerfiles |
| `mdlint` | Lint Markdown files (config: `.pymarkdownlnt.json`) |
| `help` | Show all targets and variables |

### Variables

- **IMG_BACKEND** — Backend image (default: `quay.io/$(USER)/openshift-filesystem-mcp-backend:$(VERSION)`).
- **IMG_PROXY** — Proxy image (default: `quay.io/$(USER)/openshift-filesystem-mcp-proxy:$(VERSION)`).
- **CONTAINER_ENGINE** — `podman` (default) or `docker`.
- **PLATFORM** — Build platform (default: `linux/amd64`).
- **VERSION** — Image tag (default: `git describe` or `latest`).

### Example workflow

```bash
# One-time: create SCC, grant to ServiceAccount, and (if needed) registry credentials
make apply-scc
make grant-scc
make setup-registry-credentials   # if base image pull fails

# Build, push, deploy (both images)
make container-build container-push deploy
```

## Verifying local deployment

After running `make deploy-local-dirs` and `make deploy-local`, the MCP server listens at **<http://localhost:8080>**. Use these steps to confirm it is working.

### 1. Check the container is running

In another terminal (the one that ran `make deploy-local` keeps the server in the foreground):

```bash
# With podman (default)
podman ps

# Or with docker
docker ps
```

You should see one running container with port `8080` mapped (look for `openshift-filesystem-mcp` or your `IMG_BACKEND` name).

### 2. Check the HTTP endpoint responds

The MCP server exposes `/sse` (SSE) and `/mcp` (streamable HTTP). A simple request should get a response (status or body depends on the server):

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/sse
# Expect a numeric HTTP status (e.g. 200 or 404); non-empty means the server is up
```

```bash
curl -s -i http://localhost:8080/sse
# Shows headers and start of SSE stream; confirms the MCP server is serving
```

### 3. Use an MCP client to list and read files

Configure your MCP client with the server URL **<http://localhost:8080>** (or **<http://localhost:8080/sse>** if the client expects an SSE path). Then use the client’s filesystem tools to:

- **List directories**: e.g. `/host/proc`, `/host/sys`, `/host/etc`, `/host/usr`
- **Read files**: e.g. `/host/proc/version`, `/host/proc/cpuinfo`, `/host/sys/kernel/version`, `/host/usr/share/containers/policy.json`

**In Cursor**: See [Configuring Cursor](#configuring-cursor) below.

**With MCP Inspector** (optional CLI-style check):

```bash
npx @modelcontextprotocol/inspector
```

In the inspector, connect with transport **HTTP/SSE** and URL `http://localhost:8080/sse`. Use the “Filesystem” tools to list and read under `/host/proc`, `/host/sys`, `/host/etc`, and `/host/usr`.

### 4. Sanity-check the dummy content (macOS)

On macOS, `deploy-local` uses dummy content from `.local-mcp-host/` for `/host/sys`, `/host/proc`, and `/host/usr`. After connecting with an MCP client, reading `/host/proc/version` should return a line like:

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
- “List /host/usr/share/containers” (e.g. CRI-O config)

The AI will use the filesystem tools provided by the server to list and read under `/host/etc`, `/host/sys`, `/host/proc`, and `/host/usr`.

## CI (GitHub Actions)

Two workflows run on every **push to `main`** and on every **pull request targeting `main`**:

| Workflow | Description |
|----------|-------------|
| **Lint** | Runs `make lint` (yamllint, hadolint, mdlint). Uses a Python venv and dependencies from `requirements.txt`. |
| **Container build** | Runs `make container-build` with Docker to verify both images (backend + proxy) build. Does not push to a registry. |

Config: [`.github/workflows/lint.yaml`](.github/workflows/lint.yaml), [`.github/workflows/container-build.yaml`](.github/workflows/container-build.yaml).

## Registry credentials

The Containerfiles use UBI base images from `registry.access.redhat.com` (backend: `ubi9/nodejs-22`, proxy: `ubi9/python-312`). If your cluster can pull images via the global pull-secret, no extra step is needed. Otherwise, create a secret in the deployment namespace from the OpenShift pull-secret:

```bash
make setup-registry-credentials
```

Then ensure the Deployment’s `imagePullSecrets` (or default service account) references `registry-credentials` if required by your setup.

## Security

- **No write access to the host.** Host paths are mounted **read-only** (`readOnly: true`). Both containers use a read-only root filesystem; the only writable area is an in-memory `/tmp` (emptyDir). The **backend** runs as root (`runAsUser: 0`) with `seLinuxOptions.type: spc_t` so it can read host paths under SELinux; the **proxy** runs as non-root (`runAsUser: 1001`) and does not mount host paths. The proxy **hides write/edit tools** (`write_file`, `edit_file`, `create_directory`, `move_file`) from clients so they are not exposed. Set `MCP_EXPOSE_WRITE_TOOLS=true` to expose them (e.g. for local testing with writable dirs).
- The deployment uses a custom **hostpath-readonly** SCC (see `deploy/scc-hostpath-readonly.yaml`), which allows hostPath volumes but requires read-only root filesystem. The SCC uses `runAsUser: RunAsAny` and `seLinuxContext: RunAsAny` so the backend can run as root and set `spc_t` for host path access; only the openshift-filesystem-mcp ServiceAccount is granted that SCC. Restrict who can create or use this deployment and namespace.
- The pod sets `seccompProfile.type: RuntimeDefault`. The Route uses edge TLS; treat the MCP endpoint as sensitive and limit access (network policies, auth, or cluster visibility) as appropriate for your environment.

## Tool description overrides

The proxy applies **ToolTransform** using `proxy/tools.yaml` so MCP clients (e.g. Cursor, Claude Desktop, OpenShift Lightspeed) see OpenShift-specific descriptions. It also hides write tools (`write_file`, `edit_file`, `create_directory`, `move_file`) by default; set `MCP_EXPOSE_WRITE_TOOLS=true` to expose them.

### YAML file (per-tool descriptions)

The proxy image includes `proxy/tools.yaml` with OpenShift-specific descriptions for all read-only tools. It is used by default via `MCP_TOOL_DESCRIPTIONS_FILE`. Descriptions are based on the [upstream server-filesystem](https://github.com/modelcontextprotocol/servers/blob/main/src/filesystem/index.ts).

## Project layout

```text
.
├── backend/                   # Node.js backend container (mcp-proxy + server-filesystem)
│   ├── Containerfile
│   ├── .containerignore
│   ├── Makefile
│   ├── package.json
│   └── package-lock.json
├── proxy/                     # MCP proxy with transforms (FastMCP, YAML tool overrides)
│   ├── Containerfile
│   ├── .containerignore
│   ├── Makefile
│   ├── server.py
│   ├── requirements.txt
│   └── tools.yaml              # Tool config: descriptions, renames (baked into proxy image)
├── .github/workflows/
│   ├── lint.yaml              # CI: make lint on push/PR to main
│   └── container-build.yaml   # CI: make container-build on push/PR to main
├── .pymarkdownlnt.json        # Markdown linter config
├── .yamllint.yaml             # YAML linter config
├── Makefile                   # Build, push, deploy, lint, apply-scc, grant-scc, help
├── README.md
├── requirements.txt           # Linter deps (yamllint, hadolint, pymarkdownlnt)
└── deploy/
    ├── kustomization.yaml
    ├── namespace.yaml
    ├── scc-hostpath-readonly.yaml   # Custom SCC for read-only host path mounts
    ├── deployment.yaml              # Two-container pod (backend + proxy)
    ├── service.yaml
    ├── route.yaml                   # OpenShift Route for HTTP/SSE
    └── serviceaccount.yaml
```

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for the full text.
