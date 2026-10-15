#!/usr/bin/env bash
# Agent installer: Claude Code.
# Sourced by 04-agents; do not execute directly.

agent_persist_paths() {
    printf '%s\n' .claude/ .claude.json
}

agent_installed() {
    [ -x "${AGENT_PREFIX}/bin/claude" ]
}

agent_install() {
    npm_agent_install "@anthropic-ai/claude-code"
}

agent_version() {
    "${AGENT_PREFIX}/bin/claude" --version 2>/dev/null | head -n1
}
