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
# firefox is required even though anaconda-webui doesn't hard-depend on it:
# Anaconda's WebUI renders through /usr/libexec/anaconda/webui-desktop, which
# launches firefox + cockpit-ws. Monolith removes firefox from the image, so
# without re-adding it here the install button launches liveinst but no UI ever
# appears. It only lives in the live medium; the installed system (pulled fresh
# from the registry) stays firefox-free.
dnf install -qy anaconda-live anaconda-webui firefox rsync \
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
: "${INSTALL_IMAGEREF:=forge.waywardinn.com/monolith-os/gnome:latest}"
cat >/usr/share/anaconda/interactive-defaults.ks <<EOF
ostreecontainer --url=${INSTALL_IMAGEREF} --transport=registry --no-signature-verification

# Point the installed system at the cosign-SIGNED image so future updates are
# verified (matches the README rebase target). Installed unsigned above only to
# avoid wiring cosign policy into the installer environment.
%post --erroronfail --log=/tmp/monolith-origin.log
sed -i 's|^container-image-reference=.*|container-image-reference=ostree-image-signed:docker://${INSTALL_IMAGEREF}|' \
    /ostree/deploy/*/deploy/*.origin || true
%end

# Copy the flatpaks pre-staged into the live medium onto the target, so a fresh
# install has them immediately instead of system-flatpak-setup re-downloading
# everything (slowly) on first boot. Best-effort: if the deploy path differs the
# first-boot service still installs them, so this is not --erroronfail. Shell
# vars are escaped (\$) to stay literal in the kickstart.
%post --nochroot --log=/tmp/monolith-flatpak-copy.log
set -x
for base in /mnt/sysroot /mnt/sysimage; do
    [ -d "\$base/ostree/deploy" ] || continue
    tgt=\$(ls -d "\$base"/ostree/deploy/*/deploy/*.0/var/lib 2>/dev/null | head -1)
    [ -n "\$tgt" ] || continue
    rsync -aAXUH --filter='-x security.selinux' /var/lib/flatpak "\$tgt/" && break
done
%end
EOF

# Do NOT override the dock favorites: let the live session inherit Monolith's
# own favorites from the image so its dock matches the installed system exactly.
# (Anaconda's "Install to Hard Drive" is still reachable from Show Apps.) The
# only live-session tweak is skipping the one-time GNOME welcome tour.
mkdir -p /usr/share/glib-2.0/schemas
cat >/usr/share/glib-2.0/schemas/zzzz-monolith-live.gschema.override <<'EOF'
[org.gnome.shell]
welcome-dialog-last-shown-version='4294967295'
EOF
glib-compile-schemas /usr/share/glib-2.0/schemas

# --- Materialize /opt payloads so apps like Brave launch in the live session ---
# Packages such as Brave install their real binaries under /usr/lib/opt and rely
# on a boot-time tmpfiles rule to symlink /opt/<pkg> (which is itself /var/opt/<pkg>)
# to them. The live squashfs never ran that rule, so /usr/bin/brave-origin-nightly
# is a dangling symlink and the browser won't start ("installed but won't
# launch"). Create the symlinks now so they're baked into the squashfs.
if [ -d /usr/lib/opt ]; then
    mkdir -p /var/opt
    for d in /usr/lib/opt/*/; do
        ln -sfn "$d" "/var/opt/$(basename "$d")"
    done
fi

# --- Pre-stage the system flatpaks ---
# Run the image's own bluebuild installer to put Monolith's system flatpaks into
# the live medium (so the list never drifts from the recipe). This makes the live
# session show the full app set, and the Anaconda kickstart above copies
# /var/lib/flatpak onto the target so a fresh install has them immediately rather
# than slowly re-downloading on first boot. Needs network + rw /proc/sys (above).
/usr/libexec/bluebuild/default-flatpaks/system-flatpak-setup

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
