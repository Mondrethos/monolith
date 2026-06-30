# Monolith maintainer tasks. Run `just` to list.
#
# Secure Boot: the kernel and the out-of-tree modules are signed at build time
# with a self-managed MOK key (see openssl.cnf). The public cert ships in the
# image; users enroll it after install with `ujust enroll-monolith-secure-boot-key`.
# The ISO itself is Secure-Boot-agnostic (it just installs the signed image).

set shell := ["bash", "-euo", "pipefail", "-c"]

export BB_REGISTRY := "forge.waywardinn.com"
export BB_REGISTRY_NAMESPACE := "monolith-os"

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
    @echo "Add MOK.priv as the KERNEL_SIGNING_SECRET secret in Forgejo, base64-encoded:"
    @echo "  base64 -w0 MOK.priv   # paste at forge.waywardinn.com/monolith-os/monolith/settings/actions/secrets"

# Build an installable *live* ISO for a published image, into .iso/. Mirrors the
# Generate ISO workflow: build the transient live-prep layer (iso/) on top of
# the image, then run titanoboa over it. Needs podman + sudo. (Secure Boot is
# image-side, not in the ISO; boot the live ISO with Secure Boot disabled.)
generate-iso image="forge.waywardinn.com/monolith-os/gnome-nvidia:latest":
    mkdir -p .iso
    sudo podman build \
        --cap-add sys_admin --security-opt label=disable --squash \
        --build-arg BASE_IMAGE={{image}} \
        -t localhost/monolith-live:latest \
        -f iso/Containerfile iso/
    sudo podman run --rm \
        --cap-add sys_admin --security-opt label=disable \
        -v ./iso/build_iso.sh:/src/build_iso.sh:ro \
        --mount type=image,source=localhost/monolith-live:latest,dst=/rootfs \
        -v ./.iso:/output \
        quay.io/fedora/fedora:latest \
        bash /src/build_iso.sh
