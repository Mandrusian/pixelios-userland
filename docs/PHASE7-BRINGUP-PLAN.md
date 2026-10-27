# PixelIOS Phase 7: external iOS userspace bring-up

Status: planning only. On 2026-10-27, Pixel 6 Pro (raven) hardware confirmed Phase 5.1 read-only HFS+ root, Phase 6A native PID 1, and Phase 6B process identity, stack, 16-KiB mmap. Phase 6D is a separate hardware gate for running a second Mach-O binary from HFS+ using fork/execve/wait4. CI success is not hardware validation.

## Inviolable hardware safety

- No fastboot flash, erase, format, partition write, internal UFS boot root or automatic reboot.
- Use temporary fastboot boot only after a single device is verified as unlocked raven and boot image SHA256 and source manifests match the existing gate.
- Preserve kernel arguments ufsrw=0 rootrw=0 sweetusbroot=1 sweetusbblk=0 rd=usbroot0. The USB block responder opens the external HFS+ host image O_RDONLY.
- Preserve original Phase 5.1, Phase 6A, and Phase 6B images, hashes and historical logs. New filesystem images are made from copies, never in place.
- Verify Mach-O installations, fsck, source launcher, preflight, checksums and host self-tests before each new hardware test.

## Phase 7 gates

### 7.0: Static external executable

Prove independently compiled and signed bin/pixelios-child is loaded via execve; verify two separate child PIDs, parent PID 1, wait4 status 42 and living PID 1. Report fork, execve, code signature, vnode/HFS+, wait4 and timeout failures separately. Do not infer success solely from GitHub Actions CI.

### 7.1: ABI and signing compatibility

Inventory candidate iOS binaries and required kernel and dyld ABI. Determine arm64/arm64e, pointer authentication, library path, code signatures, AMFI policy, entitlements and trust requirements. Static test executables do not establish dyld, libSystem, Foundation or Objective-C functionality.

### 7.2: Minimal read-only dynamic userland

Audit existing userland resources and manifests (home PixelIOS artifacts, PixOS-Project pixelios-userland and existing IPSW-derived material). Stage only legitimately obtained, license-compliant necessary files on a NEW external root with required loader and libraries. Track provenance, version, dependencies, hash manifests, root filesystem size, case sensitivity, links and permission requirements. A 64-MiB image is not assumed sufficient.

### 7.3: launchd and services

After dynamic load and process management, investigate a compatible real launchd and minimal services. Identify unmet kernel APIs for sandbox, AMFI, IOKit, Mach IPC, device tree, credentials, filesystem, frameworks and entitlements. A tiny static init named launchd is not Apple's launchd.

### 7.4: Display and input

Build device-specific graphics, touch, USB, power and networking support and then expand toward a real graphical iOS environment. A framebuffer console or static native PID 1 alone is not an iOS GUI boot.

## Storage and reproducibility

- Build small ARM64 Darwin binaries in macOS GitHub Actions and export audited artifacts.
- Prepare external HFS+ image copies on Fedora Asahi with separate logs and post-operation checksums.
- For large iOS root extraction, first inventory existing user assets and free space; use the user's Void x86_64 workstation if advantageous rather than redownloading IPSWs or exhausting Fedora storage.
- Never overwrite known-good hardware achievements when the next stage fails.

## Next deliverables

1. Existing IPSW/userland artifact inventory with OS build, ABI, size, origin and missing dependencies.
2. Read-only minimal dynamic root manifest and build plan.
3. First actual Raven run of a minimal dynamic executable, only after 7.0 confirms external Mach-O execution.
