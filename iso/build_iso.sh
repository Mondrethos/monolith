#!/usr/bin/env -S bash -exo pipefail
#
# Vendored from ublue-os/titanoboa build_iso.sh @ 5c457c3 (main, 2026-05-19),
# with Monolith patches to produce a HYBRID BIOS+UEFI ISO instead of titanoboa's
# UEFI-only output. titanoboa only ever masters a UEFI El Torito + GPT ESP, so
# its ISOs don't boot under legacy BIOS -- which is why they fail in GNOME Boxes
# / VirtualBox at their default (BIOS) firmware and on old CSM-only hardware.
#
# Patches vs upstream are marked "# MONOLITH:". They are confined to:
#   1. installing grub2-tools/grub2-pc-modules (for grub2-mkimage),
#   2. building a self-contained i386-pc El Torito core, and
#   3. the final xorriso command (add BIOS boot + hybrid MBR; keep UEFI).
# Everything else is upstream verbatim so re-syncing is a small diff.
#
# Run inside quay.io/fedora/fedora:latest with the live image mounted at /rootfs
# and the output dir at /output (see the Generate ISO workflow), exactly as
# titanoboa's own main.sh invokes it.

{ export PS4='+( ${BASH_SOURCE}:${LINENO} ): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'; } 2>/dev/null

# MONOLITH: + grub2-tools grub2-pc-modules, for grub2-mkimage and the i386-pc
# modules/boot stubs used to build the BIOS boot image.
dnf install -y squashfs-tools xorriso yq mtools dosfstools grub2-tools grub2-pc-modules

mkdir -p \
    /work \
    /work/iso-root \
    /work/iso-root/boot/grub2 \
    /work/iso-root/images/pxeboot \
    /work/iso-root/LiveOS
cd /work || exit 1

# Create the squashfs image of the container image
mksquashfs /rootfs /work/iso-root/LiveOS/squashfs.img -all-root -noappend -e sysroot -e ostree -comp zstd -Xcompression-level 19

iso_config_file=/rootfs/usr/lib/bootc-image-builder/iso.yaml
if [[ ! -f $iso_config_file ]]; then
    echo >&2 "ERROR: Missing /usr/lib/bootc-image-builder/iso.yaml file"
    exit 1
fi

iso_label=$(yq '.label' <$iso_config_file)

# Copy initrd and kernel
cp -av /rootfs/usr/lib/modules/*/initramfs.img /work/iso-root/images/pxeboot/initrd.img
cp -av /rootfs/usr/lib/modules/*/vmlinuz /work/iso-root/images/pxeboot/vmlinuz

# Copy GRUB modules
for grub_arch in i386-pc arm64-efi; do
    [ -f "/rootfs/usr/lib/grub/$grub_arch" ] || continue
    echo >&2 "Found $grub_arch files, copying to /work/iso-root/boot/grub2/$grub_arch ..."
    cp -avT /rootfs/usr/lib/grub/$grub_arch /work/iso-root/boot/grub2/$grub_arch
done

# Copy efi dir
cp -avT /rootfs/boot/efi/EFI /work/EFI

# Generate grub.cfg
{ grub_cfg="$(</dev/stdin)"; } <<EOF
set timeout=$(yq '.grub2.timeout // 10' <$iso_config_file)
set default="$(yq '.grub2.default // 0' <$iso_config_file)"
set menu_auto_hide=false

function load_video {
  insmod all_video
}

load_video
set gfxpayload=keep
insmod gzio
insmod part_gpt
insmod chain

search --no-floppy --set=root -l '$iso_label'

EOF
for i in $(yq '.grub2.entries | keys | .[]' <"$iso_config_file"); do
    entry_name=$(yq ".grub2.entries[$i].name" <"$iso_config_file")
    entry_linux=$(yq ".grub2.entries[$i].linux" <"$iso_config_file")
    entry_initrd=$(yq ".grub2.entries[$i].initrd" <"$iso_config_file")
    { grub_cfg+=$'\n'"$(</dev/stdin)"; } <<EOF
menuentry '$entry_name' {
  linux $entry_linux
  initrd $entry_initrd
}
EOF
done

for dir in /work/EFI/* /work/iso-root/boot/grub2; do
    echo "$grub_cfg" >"$dir/grub.cfg"
done

# For some reason, fedora also copies EFI into /boot/EFI (?), probably because of hardcoded prefix in grub/shim
cp -avT /work/EFI /work/iso-root/EFI

# MONOLITH: build the BIOS (i386-pc) El Torito boot image. Use the container's
# grub (matched to grub2-mkimage) and embed every module the core needs, so at
# BIOS boot time grub never has to load modules off the ISO -- avoiding any
# version skew with the on-ISO modules copied from the image above.
GRUB_PC=/usr/lib/grub/i386-pc
mkdir -p /work/iso-root/boot/grub2/i386-pc
grub2-mkimage \
    -O i386-pc \
    -d "$GRUB_PC" \
    -p /boot/grub2 \
    -o /work/core.img \
    biosdisk iso9660 part_msdos part_gpt fat ext2 normal configfile \
    search search_label search_fs_uuid linux echo all_video gfxterm gfxmenu \
    test true loadenv chain minicmd reboot halt
cat "$GRUB_PC/cdboot.img" /work/core.img >/work/iso-root/boot/grub2/i386-pc/eltorito.img

# Generate uefi.img
pushd /work || exit 1
truncate -s 100M /work/uefi.img
mkfs.fat -F32 /work/uefi.img
mcopy -v -i /work/uefi.img -s /work/EFI ::

# MONOLITH: hybrid xorriso. Adds the BIOS El Torito entry (first) + the grub2
# hybrid MBR, then the original UEFI entry (second, via -eltorito-alt-boot)
# pointing at the appended GPT ESP. Drops upstream's -iso_mbr_part_type, which
# --grub2-mbr now supersedes. UEFI behaviour is unchanged from upstream.
xorriso -as mkisofs \
    -R \
    -V "$iso_label" \
    -partition_offset 16 \
    --grub2-mbr "$GRUB_PC/boot_hybrid.img" \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B ./uefi.img \
    -appended_part_as_gpt \
    -c boot.catalog \
    -b boot/grub2/i386-pc/eltorito.img \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    --grub2-boot-info \
    -eltorito-alt-boot \
    -e --interval:appended_partition_2:all:: \
    -no-emul-boot \
    -iso-level 3 \
    -o "/output/$iso_label.iso" \
    iso-root
