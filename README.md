[![Build](https://github.com/Mondrethos/monolith/actions/workflows/build.yml/badge.svg)](https://github.com/Mondrethos/monolith/actions/workflows/build.yml)

Monolith is my personal Fedora Atomic desktop image, built with BlueBuild on top of Universal Blue’s Silverblue Main image. It keeps the base close to Fedora Silverblue while adding my preferred desktop defaults, GNOME extensions, system Flatpaks, gaming tools, Tailscale, Brave Origin, and layered Steam support. The image is rebuilt automatically and published to GHCR for rebasing or ISO generation.

To rebase an existing atomic Fedora installation to the latest build:

- First rebase to the unsigned image, to get the proper signing keys and policies installed:
  ```
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/mondrethos/monolith:latest
  ```
- Reboot to complete the rebase:
  ```
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/mondrethos/monolith:latest
  ```
- Reboot again to complete the installation
  ```
  systemctl reboot
  ```

The `latest` tag will automatically point to the latest build. That build will still always use the Fedora version specified in `recipe.yml`, so you won't get accidentally updated to the next major version.

## Verification

These images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). You can verify the signature by downloading the `cosign.pub` file from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/mondrethos/monolith
```
