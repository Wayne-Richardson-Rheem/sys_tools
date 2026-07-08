#!/usr/bin/env bash

# Reuse one agent socket across shells.
export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"

# Start agent only if socket is missing.
if [[ ! -S "$SSH_AUTH_SOCK" ]]; then
  eval "$(ssh-agent -a "$SSH_AUTH_SOCK")" >/dev/null
fi

# Add key only when not already loaded.
if ! ssh-add -l >/dev/null 2>&1; then
  if [[ -t 0 ]]; then
    ssh-add "$HOME/.ssh/github"
  else
    echo "[setupgithub] No TTY available; skipping ssh-add"
  fi
fi
