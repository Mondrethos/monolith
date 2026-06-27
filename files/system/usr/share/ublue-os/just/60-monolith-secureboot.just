# Monolith Secure Boot helpers (ujust).
#
# Installing from the Monolith ISO enrolls the signing key automatically (the
# MokManager screen appears on first boot). This command is only for systems
# that rebased onto a Monolith image instead, where there was no installer to
# stage the enrollment.

# Enroll the Monolith Secure Boot key - only needed if you rebased instead of installing from the ISO. Enter the password "monolith" if prompted.
enroll-secure-boot-key:
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
