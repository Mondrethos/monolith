#!/usr/bin/bash
#
# Live-ISO prep layer for Monolith. Runs ON TOP of a published Monolith edition
# image (see Containerfile) to turn that image into a bootable live-ISO rootfs
# that satisfies titanoboa's container-native ISO contract. This layer is
# transient: it is built only to feed titanoboa, never published and never the
# image users end up running (that is the FROM image, installed as-is).
#
# Modeled on ublue-os/titanoboa's examples/zirconium/src/build.sh. The single
# most important step is regenerating the initramfs with the dracut-live
# modules: that is what lets the squashfs boot as a live medium AND, crucially,
# what gives the live system a working shutdown path that unmounts the overlay
# and detaches the loop device cleanly. The old Anaconda installer boot.iso had
# no such path, which is why its end-of-install reboot hung on a grey screen.
set -exo pipefail

{ export PS4='+( ${BASH_SOURCE}:${LINENO} ): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'; } 2>/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# /proc/sys is mounted read-only in the build sandbox; livesys/dracut tooling
# expects to be able to write it. Remount rw (best-effort).
mount -o remount,rw /proc/sys || true

dnf install -y dracut-live livesys-scripts grub2-efi-x64-cdboot jq

# Regenerate the initramfs for the (swapped CachyOS) kernel WITH the live
# modules. titanoboa copies this exact file verbatim; it does not add live
# support itself, so it must already be baked in here.
kernel=$(kernel-install list --json pretty | jq -r '.[] | select(.has_kernel == true) | .version')
DRACUT_NO_XATTR=1 dracut -v --force --zstd --reproducible --no-hostonly \
    --add "dmsquash-live dmsquash-live-autooverlay" \
    "/usr/lib/modules/${kernel}/initramfs.img" "${kernel}"

# Live session: GNOME, with the autologin live user livesys-scripts sets up.
sed -i "s/^livesys_session=.*/livesys_session=gnome/" /etc/sysconfig/livesys
systemctl enable livesys.service livesys-late.service

# --- Graphical installer: Anaconda WebUI ---
# Bake Fedora's Anaconda WebUI into the live session so installing is a
# click-through "Install to Hard Drive" instead of a hand-typed `bootc install`.
# Mirrors Bazzite/Bluefin's titanoboa installer hook, trimmed to Monolith: no
# Secure Boot kickstart (enrollment stays image-side via ujust, see the workflow
# header) and no Bazzite-specific branding/tooling.
dnf install -qy anaconda-live anaconda-webui \
    libblockdev-btrfs libblockdev-lvm libblockdev-dm
mkdir -p /var/lib/rpm-state   # anaconda-webui expects this to exist

# Anaconda profile keyed to our os-release ID (recipe sets ID=monolith).
mkdir -p /etc/anaconda/profile.d
cat >/etc/anaconda/profile.d/monolith.conf <<'EOF'
[Profile]
profile_id = monolith

[Profile Detection]
os_id = monolith

[Storage]
default_scheme = BTRFS
btrfs_compression = zstd:1

[Bootloader]
efi_dir = fedora
menu_auto_hide = True
EOF

# Default kickstart: install the very image this ISO was built from. titanoboa
# squashes only the rootfs (no embedded container copy), so Anaconda pulls the
# image from the registry at install time. INSTALL_IMAGEREF is passed in from
# the Containerfile's BASE_IMAGE.
: "${INSTALL_IMAGEREF:=ghcr.io/mondrethos/monolith-gnome:latest}"
cat >/usr/share/anaconda/interactive-defaults.ks <<EOF
ostreecontainer --url=${INSTALL_IMAGEREF} --transport=registry --no-signature-verification

# Point the installed system at the cosign-SIGNED image so future updates are
# verified (matches the README rebase target). Installed unsigned above only to
# avoid wiring cosign policy into the installer environment.
%post --erroronfail --log=/tmp/monolith-origin.log
sed -i 's|^container-image-reference=.*|container-image-reference=ostree-image-signed:docker://${INSTALL_IMAGEREF}|' \
    /ostree/deploy/*/deploy/*.origin || true
%end
EOF

# Surface the installer in the GNOME dock/overview for the live user, and skip
# the GNOME welcome tour on the live session.
mkdir -p /usr/share/glib-2.0/schemas
cat >/usr/share/glib-2.0/schemas/zz1-monolith-live.gschema.override <<'EOF'
[org.gnome.shell]
favorite-apps = ['liveinst.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Console.desktop']
welcome-dialog-last-shown-version='4294967295'
EOF
glib-compile-schemas /usr/share/glib-2.0/schemas

# The contract expects shim + grub EFI binaries under /boot/efi/EFI/$VENDOR, but
# Universal Blue images keep them in /usr/lib/efi. Stage them across, add the
# CD-boot grub (grub2-efi-x64-cdboot -> gcdx64.efi), and the removable-media
# fallback binary.
mkdir -p /boot/efi
cp -av /usr/lib/efi/*/*/EFI /boot/efi/
cp -v /boot/efi/EFI/fedora/grubx64.efi /boot/efi/EFI/BOOT/fbx64.efi

# A booted live / is a small tmpfs-backed overlay, so /var/tmp is tiny. ostree
# needs real scratch space there during `bootc install`; mount a larger tmpfs.
cat >/etc/systemd/system/var-tmp.mount <<'EOF'
[Unit]
Description=Larger tmpfs for /var/tmp on the live system

[Mount]
What=tmpfs
Where=/var/tmp
Type=tmpfs
Options=size=50%%,nr_inodes=1m

[Install]
WantedBy=local-fs.target
EOF
systemctl enable var-tmp.mount

# The ISO contract config titanoboa's build_iso.sh reads for label + GRUB menu.
mkdir -p /usr/lib/bootc-image-builder
cp "$SCRIPT_DIR/iso.yaml" /usr/lib/bootc-image-builder/iso.yaml
