#!/usr/bin/env bash
# Puts operator-installed agents and tools on PATH for interactive shells,
# including the shells Paseo spawns for its agents.

for dir in /config/tools/bin /config/agents/bin; do
    case ":${PATH}:" in
        *":${dir}:"*) ;;
        *) PATH="${dir}:${PATH}"; export PATH ;;
    esac
done
unset dir

# uv keeps everything it installs under /config, so a tool you install from a
# pane survives a container recreate exactly as one named in PYTHON_TOOLS
# does, and an `uvx some-mcp-server` pays its download cost once rather than
# once per recreate. UV_PYTHON_INSTALL_DIR matters most: a virtualenv built
# against the image's own Python breaks when a later image ships a new Python
# minor version, so uv is pointed at an interpreter that lives in /config
# beside the virtualenvs it belongs to, and only-managed keeps it from
# quietly falling back to the image's Python when one is already there.
export UV_TOOL_DIR=/config/tools/uv/tools
export UV_TOOL_BIN_DIR=/config/tools/bin
export UV_PYTHON_INSTALL_DIR=/config/tools/uv/python
export UV_PYTHON_PREFERENCE=only-managed
export UV_CACHE_DIR=/config/tools/uv/cache

if [ -r /run/paseo-container-umask ]; then
    umask "$(cat /run/paseo-container-umask)" 2>/dev/null || true
fi
