#!/bin/bash
set -e

FAIL=0

echo "[CHECK] Scanning system for sensitive material..."

# --- SSH ---
if [ -d ~/.ssh ]; then
  if ls ~/.ssh | grep -vq '^known_hosts$'; then
    echo "❌ SSH private keys detected"
    FAIL=1
  else
    echo "✅ SSH directory clean"
  fi
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

