#!/usr/bin/env bash
#
# Sign the CachyOS vmlinuz with the Monolith MOK key so it boots under Secure
# Boot. Unlike Universal Blue / BlueBuild's base images (which keep the
# Fedora-signed stock kernel and only need to sign modules), we swap in the
# CachyOS kernel, which ships unsigned -- shim/GRUB reject it under Secure Boot
# until it carries a signature from an enrolled key. We re-sign it here at build
# time with the same key we enroll as a MOK and use for the NVIDIA modules.
#
# Inputs (provided by the recipe's `script` module):
#   PUBLIC_KEY_DER_PATH  - the cert baked into the image (env)
#   /tmp/certs/private_key.priv - MOK private key (mounted build secret)

set -oue pipefail

KERNEL_VERSION="$(ls /usr/lib/modules)"
if [ "$(printf '%s\n' "$KERNEL_VERSION" | wc -l)" -ne 1 ]; then
  echo "expected exactly one kernel in /usr/lib/modules, found: $KERNEL_VERSION" >&2
  exit 1
fi

PRIVATE_KEY_PATH="/tmp/certs/private_key.priv"
PUBLIC_KEY_CRT_PATH="/tmp/certs/public_key.crt"
openssl x509 -inform DER -in "$PUBLIC_KEY_DER_PATH" -out "$PUBLIC_KEY_CRT_PATH"

# sbsigntools provides sbsign/sbverify; pull it in just for this step.
dnf install -y --setopt=install_weak_deps=False sbsigntools

vmlinuz="/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"
sbsign --key "$PRIVATE_KEY_PATH" --cert "$PUBLIC_KEY_CRT_PATH" \
  "$vmlinuz" --output "${vmlinuz}.signed"
mv "${vmlinuz}.signed" "$vmlinuz"

# Fail the build if the signature did not take.
sbverify --cert "$PUBLIC_KEY_CRT_PATH" "$vmlinuz"

# Leave nothing behind: the tool isn't needed at runtime.
dnf remove -y sbsigntools || true
