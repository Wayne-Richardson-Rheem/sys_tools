#!/bin/bash
set -e

FAIL=0

echo "[CHECK] Scanning system for sensitive material..."

# --- SSH PRIVATE KEYS ---
SSH_DIR="$HOME/.ssh"

if [ -d "$SSH_DIR" ]; then
    PRIVATE_KEYS=$(grep -aEl \
        '-----BEGIN (OPENSSH|RSA|EC|DSA|PRIVATE) KEY-----' \
        "$SSH_DIR"/* 2>/dev/null || true)

    if [ -n "$PRIVATE_KEYS" ]; then
        echo "❌ SSH private keys detected:"
        echo "$PRIVATE_KEYS"
        FAIL=1
    else
        echo "✅ No SSH private keys detected"
    fi
else
    echo "✅ No SSH directory"
fi

# --- GPG PRIVATE KEYS ---
if [ -d ~/.gnupg/private-keys-v1.d ]; then
  if [ "$(ls -A ~/.gnupg/private-keys-v1.d)" ]; then
    echo "❌ GPG private keys detected"
    FAIL=1
  else
    echo "✅ No GPG private keys present"
  fi
else
  echo "✅ No GPG private key directory"
fi

# --- GitHub CLI credentials ---
if [ -d ~/.config/gh ]; then
  echo "❌ GitHub CLI credentials detected"
  FAIL=1
else
  echo "✅ No GitHub CLI credentials"
fi

# --- Final ---
if [ "$FAIL" -ne 0 ]; then
  echo
  echo "❌ Sensitive material detected — abort image build"
  exit 1
fi

echo

