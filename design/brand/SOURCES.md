# CodePax app icon

The current app icon is `codepax-terminal-concept-v2.png`, generated with the built-in image generation tool and selected by the user on 2026-11-24. It depicts an ivory miniature terminal on a blue background with a mint prompt and orange status light. The same artwork is packaged as the 1024px opaque home-screen icon and the 512px in-app brand image.

Run `swift scripts/generate_icon.swift` from the repository root to regenerate both assets from this source without changing the composition.

## Previous headset portrait

Generated with the built-in image generation tool, using the following public Keduo character assets as identity references:

- https://github.com/zhisandesu/codex-desktop-pet/blob/main/docs/media/keduo-1.0-cover-4x3.png
- https://github.com/zhisandesu/codex-desktop-pet/blob/main/XiaobianPet/Assets/animations/click-flick-fall/00.png

The character, costume, hair and eye colors follow those references. The preview adds a headset and boom microphone and uses a dark icon background. Selected by the user as the Code Pax app icon. The approved source is `code-pax-headset-source.png`; the final generation prompt is preserved in `code-pax-headset-prompt.txt`.

The original portrait and its prompt are retained as historical sources for the companion character and its animations.

## Thinking action frames (0.12.2)

- Source: `animation/thinking-sheet-v1.png`, generated with built-in imagegen using the approved headset portrait as edit target.
- Prompt: `animation/thinking-prompt.txt` (identity-preserving 2×2 four-pose sheet).
- Packaged without redraw by `scripts/package_thinking_frames.swift`; retains the reference provenance documented above.
