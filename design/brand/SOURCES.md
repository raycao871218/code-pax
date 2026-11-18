# Code Pax headset portrait

Generated with the built-in image generation tool, using the following public Keduo character assets as identity references:

- https://github.com/zhisandesu/codex-desktop-pet/blob/main/docs/media/keduo-1.0-cover-4x3.png
- https://github.com/zhisandesu/codex-desktop-pet/blob/main/XiaobianPet/Assets/animations/click-flick-fall/00.png

The character, costume, hair and eye colors follow those references. The preview adds a headset and boom microphone and uses a dark icon background. Selected by the user as the Code Pax app icon. The approved source is `code-pax-headset-source.png`; the final generation prompt is preserved in `code-pax-headset-prompt.txt`.

Run `swift scripts/generate_icon.swift` from the repository root to generate the opaque 1024px home-screen icon and the 512px in-app asset without changing the artwork.

## Thinking action frames (0.12.2)

- Source: `animation/thinking-sheet-v1.png`, generated with built-in imagegen using the approved headset portrait as edit target.
- Prompt: `animation/thinking-prompt.txt` (identity-preserving 2×2 four-pose sheet).
- Packaged without redraw by `scripts/package_thinking_frames.swift`; retains the reference provenance documented above.
