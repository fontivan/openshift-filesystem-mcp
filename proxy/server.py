#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# MCP proxy with transforms: tool description overrides and write-tool visibility.
# Proxies to Node.js backend (mcp-proxy + server-filesystem) and applies YAML config.

import os
from pathlib import Path

from fastmcp import FastMCP
from fastmcp.server import create_proxy
from fastmcp.server.transforms import ToolTransform, Visibility
from fastmcp.tools.tool_transform import ToolTransformConfig
import yaml

WRITE_TOOLS = {"write_file", "edit_file", "create_directory", "move_file"}


def load_tool_config() -> dict[str, ToolTransformConfig]:
    """Load tool descriptions from YAML and build ToolTransformConfig."""
    config: dict[str, ToolTransformConfig] = {}
    path = os.environ.get("MCP_TOOL_DESCRIPTIONS_FILE")
    if path and Path(path).exists():
        try:
            with open(path, encoding="utf-8") as f:
                data = yaml.safe_load(f)
            for entry in data.get("tools", []) or []:
                if isinstance(entry, dict) and "name" in entry:
                    kwargs: dict[str, object] = {}
                    if "description" in entry:
                        kwargs["description"] = entry["description"]
                    if "rename" in entry:
                        kwargs["name"] = entry["rename"]
                    config[entry["name"]] = ToolTransformConfig(**kwargs)
        except (yaml.YAMLError, OSError) as e:
            print(f"Warning: failed to load tool descriptions from {path}: {e}")

    return config


def main() -> None:
    backend_url = os.environ.get(
        "MCP_BACKEND_URL", "http://127.0.0.1:8081/mcp"
    )
    port = int(os.environ.get("PORT", "8080"))

    expose_write = os.environ.get("MCP_EXPOSE_WRITE_TOOLS", "").lower() == "true"

    mcp = FastMCP("openshift-filesystem-mcp")
    mcp.mount(create_proxy(backend_url))
    # Apply tool transform at server level (mount() can return None for proxies)
    mcp.add_transform(ToolTransform(load_tool_config()))
    if not expose_write:
        mcp.add_transform(Visibility(False, names=WRITE_TOOLS))

    if __name__ == "__main__":
        mcp.run(transport="http", host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
