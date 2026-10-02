# Aniwave Manual

Oct 2, 2026 · @Zafio

## Quick start

Aniwave adds a wave (sine, noise and more) on top of your animation without changing your keys. Needs Godot 4.3 or newer.

1. Copy `addons/aniwave` into your project, then enable **Aniwave** in Project → Project Settings → Plugins.
2. Add an **Aniwave** node to the scene. Set **Animation Mixer** to your AnimationPlayer.
3. Click the 🔍 next to **Property** and pick what to move (for example `position` or a material's emission). Tick the **Axes** you want, then press play.

## Settings

| Setting | What it does |
| --- | --- |
| Mode | Wave shape: Sine, Noise, Triangle, Square, Sawtooth, Random Steps or a Curve you draw |
| Amplitude | How far the wave pushes the value. Can be keyed in the animation |
| Frequency | Speed in waves per second. Can be keyed; the wave follows your keys smoothly |
| Axes | Which components move: X/Y/Z, or R/G/B/A for colors. Hidden for single numbers |
| Polarity | Both ways, only up (Positive) or only down (Negative) from the keyed value |
| Polarity Shape | How the unused half is handled: Remap (smooth), Clamp (rests) or Bounce (mirrored) |
| Fade In / Fade Out | Seconds to grow the effect in at the start and out at the end, so loops join cleanly |
| Phase, Time Offset | Shift the wave inside its cycle, or shift it in time |
| Time Source | Animation (follows the playhead, can be scrubbed) or Global (engine time, for AnimationTree) |
| Preview In Editor | Untick to see your raw keys while editing |

A few more settings appear only for some modes: Pulse Width and Smoothing (Square, Sawtooth), Seed (Noise, Random Steps), Octaves and Roughness (Noise), Curve (Curve).

## Modulation

One Aniwave can control another's strength or speed, for example a slow sine that makes noise swell and calm down.

1. Add a second Aniwave and tick **Modulator Only**. Pick its wave (Mode, Frequency, Phase, Polarity).
2. On the Aniwave you want to control, open **Modifier → Modulation** and drag the modulator into **Amplitude Modulator** and/or **Frequency Modulator**.
3. Set the **Depth** for each.

- **Amplitude Depth (0 to 1):** 1 = the wave moves the amplitude from nothing up to your Amplitude. 0.5 = between half and full. 0 = no effect.
- **Frequency Depth:** like vibrato. 0.5 = the speed swings between 50% and 150% of Frequency.
- A modulator only uses its wave shape and speed. Its own Amplitude and Fade are ignored.

## Tips and limits

- **Stacking:** several Aniwaves can drive the same property. Their offsets add up. Use one node per property.
- **Safe to key:** the node never changes your animation. Keys you insert while the wave is showing are corrected automatically, and the scene file stays clean.
- **Materials:** a material is shared by every model that uses it. To move just one model, give it its own material (Surface Material Override) first. Emission only shows if Emission is enabled on the material.
- **Keys not working?** If a keyed Amplitude or Frequency has no effect, delete those tracks and add them again.
- **Frequency changes and modulation need** an AnimationPlayer and Time Source = Animation to be scrubbable. With Global time or an AnimationTree they still work, but not backwards.
- **Cost:** about 12 to 17 µs per active modifier per frame; idle ones are almost free.
- **Upgrading from Anim Modifier (v1.x):** replace `res://addons/anim_modifier/anim_modifier.gd` with `res://addons/aniwave/aniwave.gd` in your `.tscn` files.
