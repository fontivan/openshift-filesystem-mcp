# SPDX-License-Identifier: Apache-2.0
# MCP server-filesystem with stdio-to-SSE/HTTP bridge for OpenShift
# Uses Red Hat UBI9 Node.js 22; host /etc, /sys, /proc are mounted at /host/* at runtime.

FROM registry.access.redhat.com/ubi9/nodejs-22:latest@sha256:6411ae77358bab07718f2c3dfdd44bf0d2c32f1ee5938d4471c3df693f4b3492

ENV SUMMARY="MCP server-filesystem over HTTP/SSE for OpenShift" \
    DESCRIPTION="Model Context Protocol filesystem server with read-only access to host /etc, /sys, /proc, exposed via HTTP/SSE transport."

LABEL name="openshift-filesystem-mcp" \
      summary="${SUMMARY}" \
      description="${DESCRIPTION}" \
      io.k8s.display-name="openshift-filesystem-mcp" \
      io.k8s.description="${DESCRIPTION}" \
      io.openshift.tags="mcp,filesystem,nodejs"

# Install mcp-proxy and server-filesystem in image
RUN npm install -g mcp-proxy@latest @modelcontextprotocol/server-filesystem@latest

# Use /tmp for npm cache so npx works with readOnlyRootFilesystem (runtime /tmp is emptyDir)
ENV NPM_CONFIG_CACHE=/tmp/.npm

# Default port for HTTP/SSE (override with PORT env if needed)
ENV PORT=8080
EXPOSE 8080

# Run mcp-proxy wrapping server-filesystem; paths /host/etc, /host/sys, /host/proc
# are provided by the Deployment's volume mounts from the host.
ENTRYPOINT ["npx", "mcp-proxy", "--port", "8080", "--"]
CMD ["npx", "@modelcontextprotocol/server-filesystem", "/host/etc", "/host/sys", "/host/proc"]
