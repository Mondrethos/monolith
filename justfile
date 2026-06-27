# Monolith maintainer tasks. Run `just` to list.
#
# Secure Boot: the kernel and the out-of-tree modules are signed at build time
# with a self-managed MOK key (see openssl.cnf). The public cert ships in the
# image and is enrolled via the ISO installer (BB_GENISO_* below), so users get
# the MokManager screen on first boot and just type the enrollment password.

set shell := ["bash", "-euo", "pipefail", "-c"]

export BB_REGISTRY := "ghcr.io"
export BB_REGISTRY_NAMESPACE := "mondrethos"

# Baked into generated ISOs so first-boot MOK enrollment is automatic: the
# installer pre-stages the cert and MokManager prompts for this password.
export BB_GENISO_SECURE_BOOT_URL := "https://github.com/Mondrethos/monolith/raw/main/files/system/etc/pki/akmods/certs/akmods-monolith.der"
export BB_GENISO_ENROLLMENT_PASSWORD := "monolith"
export BB_GENISO_VARIANT := "Silverblue"

_default:
    @just --list

# Build a recipe locally (needs MOK.priv present; run generate-secureboot-key first).
build recipe="recipes/recipe-gnome-nvidia.yml":
    bluebuild build {{recipe}}

# Generate the MOK keypair: MOK.priv (gitignored, -> CI secret) + the public
# .der baked into the image. 100-year validity so enrolled machines never need
# re-enrollment. Run once; re-running rotates the key and forces re-enrollment.
generate-secureboot-key:
    openssl req -config ./openssl.cnf \
        -new -x509 -newkey rsa:2048 \
        -nodes -days 36500 -outform DER \
        -keyout ./MOK.priv \
        -out ./files/system/etc/pki/akmods/certs/akmods-monolith.der
    @echo
    @echo "Wrote MOK.priv (keep secret) and files/system/.../akmods-monolith.der (commit)."
    @echo "Add MOK.priv to GitHub as the KERNEL_SIGNING_SECRET secret, base64-encoded:"
    @echo "  base64 -w0 MOK.priv | gh secret set KERNEL_SIGNING_SECRET"

# Build an installable ISO for a published image, with Secure Boot key
# pre-enrollment baked in (BB_GENISO_* above). Pass an image ref or use the
# default NVIDIA edition.
generate-iso image="ghcr.io/mondrethos/monolith-gnome-nvidia:latest":
    mkdir -p .iso
    bluebuild generate-iso \
        --iso-name "$(basename {{image}} | tr ':' '-').iso" \
        --output-dir .iso/ \
        image {{image}}
