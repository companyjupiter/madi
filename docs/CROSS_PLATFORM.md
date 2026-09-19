# Cross-platform product plan

Madi must support Windows, macOS, and Linux. The current product
path is optimized for Apple Silicon macOS, so cross-platform support needs
explicit platform boundaries instead of ad-hoc conditionals.

## Current support

| Layer | Current implementation | Portability status |
| --- | --- | --- |
| Engine contract | CLI arguments plus STREAM stdin/stdout events | Mostly portable contract |
| macOS engine | Zig + Metal/MSL + MPS + Accelerate | macOS Apple Silicon only |
| Windows engine | Legacy/root Zig CUDA code loading `nvcuda.dll` | Exists, not product-integrated |
| Linux engine | None selected | Needs CUDA and/or CPU backend |
| Desktop app | SwiftUI + CoreAudio/AVFoundation | macOS only |
| Packaging | `.app`, codesign, notarization, DMG | macOS only |
| Dashboard | Vite web dashboard | Portable as web UI |

## Target architecture

```text
app shell / CLI
  -> audio adapter
  -> engine launcher
  -> stable engine event protocol
  -> selected engine backend
       - macOS: Metal
       - Windows: CUDA or CPU fallback
       - Linux: CUDA and/or CPU fallback
```

The engine event protocol should remain backend-neutral. App code should not
know whether the engine process is Metal, CUDA, Vulkan, or CPU; it should only
know the executable path, model path, asset root, stream roots, and event schema.

## Platform requirements

### macOS

- Keep the existing Apple Silicon Metal path working.
- Keep Developer ID packaging until a replacement app shell exists.
- Preserve current live meeting capture behavior.

### Windows

- Integrate a Windows engine build into the product launcher.
- Use WASAPI or a portable audio library for live meeting capture.
- Provide a signed installer or zip artifact.
- Define model/cache locations under the user's local app data directory.

### Linux

- Add a Linux engine backend, preferably CUDA first and CPU fallback second.
- Use PulseAudio, PipeWire, or ALSA through a portable audio layer.
- Provide AppImage, deb/rpm, or tar artifacts.
- Define model/cache locations under XDG directories.

## Implementation milestones

1. Stabilize the backend-neutral engine contract.
2. Split engine builds by backend name, for example:
   - `sovereign-engine-metal`
   - `sovereign-engine-cuda`
   - `sovereign-engine-cpu`
3. Introduce a cross-platform app/audio shell or CLI launcher.
4. Add platform-specific model/cache directory handling.
5. Add CI build validation for macOS, Windows, and Linux.
6. Add release packaging for each supported OS.

## Open issues

- #99 tracks the cross-platform product goal.
- #100 tracks engine backend abstraction.
- #101 tracks the portable app/audio shell.
- #102 tracks Windows/Linux build and package validation.
