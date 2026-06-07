#!/usr/bin/env bash
# Provenance check for the vendored case studies (Section H).
#
# Proves two things, reproducibly, for each system:
#   (1) the commit pinned in VERSION.md is the commit the upstream tag points to;
#   (2) our vendored policy-bearing source files are byte-identical (SHA-256) to
#       the upstream files at that commit.
#
# This is tier-1 "provenance" verification: it does NOT re-run gas tests (do that
# with `forge test` inside each casestudy dir) and it does NOT diff the on-chain
# deployed bytecode (out of scope — see VERSION.md / final-report limitations).
#
# Requires: curl, sha256sum (or shasum), grep. Network access to github.com.
# Usage:  bash casestudy/verify-pins.sh        # exits 0 iff every check passes
set -uo pipefail
cd "$(dirname "$0")"

fail=0
sha() { command -v sha256sum >/dev/null && sha256sum | cut -d' ' -f1 || shasum -a 256 | cut -d' ' -f1; }

# system | upstream owner/repo | tag | pinned commit | space-separated src paths to hash
check() {
  local name="$1" repo="$2" tag="$3" pin="$4"; shift 4
  local files=("$@")
  echo "── $name ($repo @ $tag)"

  # (1) tag -> commit, dereferenced (commits/<ref> resolves annotated tags too)
  local up
  up=$(curl -s "https://api.github.com/repos/$repo/commits/$tag" | grep -oE '"sha": "[0-9a-f]{40}"' | head -1 | grep -oE '[0-9a-f]{40}')
  if [ "$up" = "$pin" ]; then
    echo "   ✓ tag $tag → $up  (matches VERSION.md pin)"
  else
    echo "   ✗ tag $tag → ${up:-<none>}  EXPECTED $pin"; fail=1
  fi

  # (2) vendored source SHA-256 == upstream raw at the pinned commit
  for f in "${files[@]}"; do
    if [ ! -f "$name/$f" ]; then echo "   ✗ local missing: $name/$f"; fail=1; continue; fi
    local loc rem
    loc=$(sha < "$name/$f")
    rem=$(curl -sL "https://raw.githubusercontent.com/$repo/$pin/$f" | sha)
    if [ "$loc" = "$rem" ]; then
      echo "   ✓ $f  ($loc)"
    else
      echo "   ✗ $f  local=$loc  upstream=$rem"; fail=1
    fi
  done
}

# Pins are duplicated here from each VERSION.md on purpose: this script is the
# executable witness that VERSION.md's claims hold. Keep them in sync.
check coinbase coinbase/spend-permissions v1.0.0 \
  54e99c7e73846418c9b5d2b4139c17d415a27d41 \
  src/SpendPermissionManager.sol

check metamask MetaMask/delegation-framework v1.3.0 \
  bfbdf9795a976833ed2fa000baf42fbb83958b03 \
  src/DelegationManager.sol src/enforcers/NativeTokenTransferAmountEnforcer.sol

echo
if [ "$fail" -eq 0 ]; then echo "PROVENANCE OK — all pins and source hashes verified."; else echo "PROVENANCE FAILED — see ✗ above."; fi
exit "$fail"
