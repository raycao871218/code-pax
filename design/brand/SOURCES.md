# CodePax app icon

The current app icon is `codepax-girls-duo-v9.png`, generated with the built-in image generation tool on 2026-11-27 using the previous duo icon as a character identity reference. Following the user's preference for an interacting duo, Codex sits slightly higher and gently pokes Claude's cheek with a mischievous smile; Claude looks up with a blushing, indignant pout. Their white/lavender and orange/cream identities remain distinct. It is packaged as the 1024px opaque home-screen icon and independent 512px `CodePaxLogo` image. The full generation prompt is in `codepax-girls-duo-v9-prompt.txt`; `codepax-girls-duo-v9-64.png` is a small-size review export. Earlier icon sources remain as historical designs. The reference app icons informed the interaction and diagonal composition only; no third-party icon artwork was composited into this asset.

The assistant avatars use the neutral, focused expressions from the eight-frame motion library documented below. Earlier `codepax-girls-duo-v7.png` established the duo's identities and personality direction. The original Codex character portrait from commit `3e89ecf` remains preserved as `code-pax-headset-source.png`. Chat avatars select independent artwork using the session's agent; app branding uses `BrandMark`. Generating app icons must never overwrite character portraits or thinking frames.

## Per-agent chat portraits and thinking frames (2026-11-27)

Both sheets were generated with the built-in imagegen tool, using `codepax-girls-duo-v7.png` as the identity and style reference:

- `animation/codex-personality-sheet-v2.png`: Codex's composed smile and thoughtful/blinking poses; prompt in `animation/codex-personality-prompt.txt`.
- `animation/claude-personality-sheet-v1.png`: Claude's proud pout, blush and thoughtful/blinking poses; prompt in `animation/claude-personality-prompt.txt`.

These four-frame personality sheets are historical references. The active chat artwork now uses the eight-frame focused motions below. Existing custom portrait/animation settings apply to Codex only, preventing them from overriding Claude. Source provenance for Claude's reference is in `claude-girl-reference-SOURCES.md`.

## Eight-frame motion library (2026-11-27)

The user requested smoother blinks, more frames and varied working expressions rather than permanent personality expressions. The active library has six motions per character, eight frames each, for 96 runtime frames. Each motion has two fully closed-eye drawings, with brief closing/opening transitions. Normal playback holds the closed frames for a combined 150ms. Working faces are focused, attentive or mildly curious; completion uses a relieved smile.

The built-in imagegen tool generated three 4x4 sheets for each character, using that character's preceding portrait as an identity/style reference:

- `animation/{codex,claude}-focus-sheet-v2.png`: first eight cells Thinking, last eight Reading.
- `animation/{codex,claude}-work-sheet-v2.png`: first eight Typing, last eight Replying.
- `animation/{codex,claude}-rest-sheet-v2.png`: first eight Celebrating, last eight Focusing.

The full prompts are the six matching `animation/{codex,claude}-{focus,work,rest}-v2-prompt.txt` files. Cells are read left to right, top to bottom. Frames are packaged at 320px; Focusing frame zero supplies the neutral static portrait. Runtime names are `{CodePax,Claude}{Thinking,Reading,Typing,Replying,Celebrating,Focusing}0...7`.

On macOS, regenerate with `swift scripts/package_smooth_motion_frames.swift codex` and the same command with `claude`. On Windows, run `powershell -File scripts/package_smooth_motion_frames.ps1 codex`, repeat with `claude`, then `node scripts/assemble_motion_previews.mjs`. The old four-frame generators explicitly redirect to prevent partially overwriting the new library.

Twelve `animation/{codex,claude}-{thinking,reading,typing,replying,celebrating,focusing}-preview.gif` files show the packaged frames with runtime timing. Working motions rotate after two complete loops within the activity's motion pool; their starting variant changes between activities. Completion plays once and holds its last frame. Reduced motion and background scene handling remain supported. Custom Codex animations retain their imported frame timing.

The earlier `codepax-terminal-concept-v2.png` terminal icon is retained as a historical design.

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
