<div align="center">
  <img src="files/system/usr/share/plymouth/themes/spinner/watermark.png#gh-dark-mode-only" alt="Monolith" width="200"/>
</div>

[![Build](https://github.com/Mondrethos/monolith/actions/workflows/build.yml/badge.svg)](https://github.com/Mondrethos/monolith/actions/workflows/build.yml)

Monolith is my personal Fedora Atomic desktop image, built with BlueBuild on top of Universal Blue’s Silverblue Main image. It keeps the base close to Fedora Silverblue while adding my preferred desktop defaults, GNOME extensions, system Flatpaks, gaming tools, Tailscale, Brave Origin, and layered Steam support. Every edition runs the CachyOS kernel. Images are rebuilt automatically and published to GHCR for rebasing or ISO generation.

## Pick your edition

Monolith comes in a few flavors — choose the one that matches your hardware:

| Edition | Image | Use this if… |
| --- | --- | --- |
| **GNOME** | `monolith-gnome` | You have AMD or Intel graphics (the default for most machines). |
| **GNOME — NVIDIA** | `monolith-gnome-nvidia` | You have an NVIDIA GPU. Adds NVIDIA’s open kernel module, built against the CachyOS kernel. |

All images live under `ghcr.io/mondrethos/`. In the commands below, replace `<edition>` with the image name from the table (e.g. `monolith-gnome` or `monolith-gnome-nvidia`).

## Rebasing

To rebase an existing atomic Fedora installation to the latest build of your chosen edition:

- First rebase to the unsigned image, to get the proper signing keys and policies installed:
  ```
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/mondrethos/<edition>:latest
  ```
- Reboot to complete the rebase:
  ```
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/mondrethos/<edition>:latest
  ```
- Reboot again to complete the installation
  ```
  systemctl reboot
  ```

The `latest` tag will automatically point to the latest build. That build will still always use the Fedora version specified in your edition’s recipe (`recipes/recipe-<edition>.yml`), so you won't get accidentally updated to the next major version.

## Verification

These images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). You can verify the signature by downloading the `cosign.pub` file from this repo and running the following command (substituting your edition):

```bash
cosign verify --key cosign.pub ghcr.io/mondrethos/<edition>
```
