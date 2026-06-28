# Monolith Secure Boot helpers (ujust).
#
# Installing from the Monolith ISO enrolls the signing key automatically (the
# MokManager screen appears on first boot). This command is only for systems
# that rebased onto a Monolith image instead, where there was no installer to
# stage the enrollment.
#
# Deliberately NOT named "enroll-secure-boot-key": the ublue base ships that
# recipe in 00-default.just, which is imported before this file. Same-named
# recipes can't override an earlier sibling import, so a collision would just
# be shadowed by the upstream version (akmods-ublue.der / "universalblue").
# A distinct name guarantees this recipe is the one that runs.

# Enroll the Monolith Secure Boot key - only needed if you rebased instead of installing from the ISO. Enter the password "monolith" if prompted.
enroll-monolith-secure-boot-key:
    #!/usr/bin/bash
    set -euo pipefail
    ENROLLMENT_PASSWORD="monolith"
    SECUREBOOT_KEY=/etc/pki/akmods/certs/akmods-monolith.der
    if [ ! -f "$SECUREBOOT_KEY" ]; then
        echo "Secure Boot key not found at $SECUREBOOT_KEY" >&2
        exit 1
    fi
    sudo mokutil --timeout -1
    echo -e "$ENROLLMENT_PASSWORD\n$ENROLLMENT_PASSWORD" | sudo mokutil --import "$SECUREBOOT_KEY"
    echo 'At the next reboot the MokManager UEFI menu appears (QWERTY input).'
    echo 'Select "Enroll MOK", then enter the password "monolith".'
