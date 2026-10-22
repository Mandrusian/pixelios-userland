# PixeliOS: iOS userland

The recipe that builds the **iOS 16.7 root filesystem** for the PixeliOS port (Apple XNU and iOS on a Google Pixel 6a,
Tensor G1). The root is flashed to the phone's `userdata` partition and mounted by the patched kernel.

> **AI-driven development.** This project is written mostly by AI coding agents under the direction of a human maintainer, who owns the phone
> and decides what is flashed or published. Read the code before you trust it. Details: [docs/AI_DEVELOPMENT.md](docs/AI_DEVELOPMENT.md).

This repository holds scripts only. **No Apple binaries are distributed**: the IPSW restore image is downloaded on your
own machine and the root is assembled from it there.

Status (*observed on hardware*, 2026-10-22): the root built with this recipe boots to launchd, the lock screen and the home screen
on a Pixel 6a; touch works, the UI is slow, and Wi-Fi, GPU, audio, camera and modem are not done. Details are in
[pixelios-site](https://github.com/PixOS-Project/pixelios-site) (`docs/STATUS.md`).

- `tools/build-ios-root.sh`, `tools/build-ios-root-rootless.sh`: build the root (the rootless variant needs no sudo,
  see `docs/ROOTLESS_BUILD.md`)
- `tools/mkiosroot.sh`, `tools/mkinit.py`, `tools/sweet-init.S`, `tools/sweet-root-tweaks.py`, `tools/patch-launchd-plist.py`:
  image assembly, init and launchd tweaks
- `tools/ios-root-plan.py`, `tools/check-ios-root.py`: plan and verify a root before flashing

Some files derive from [ios-sweet](https://github.com/dipa-studio/ios-sweet) (no license): they are not copied here; run
`tools/setup-upstream.sh` to fetch the pinned upstream and apply our diffs in `upstream-patches/`.

Other repositories: [pixelios-kernel](https://github.com/PixOS-Project/pixelios-kernel) (shim, XNU patches, boot tools),
[pixelios-site](https://github.com/PixOS-Project/pixelios-site) (docs and status). Our code is MIT; read
`SECURITY.md` and `CONTRIBUTING.md`.
