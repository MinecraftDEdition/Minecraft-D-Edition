# Input, water, item faces, and pause music

Development changes (not published):

- Keyboard, mouse actions, and controller input are gated on game-window focus. Losing focus releases mouse capture and clears pending gameplay actions; capture resumes when the gameplay window regains focus.
- Grounded players whose eyes are above water can use the normal jump impulse. Swimming against an unobstructed bank also receives an exit impulse when the raised player bounds are clear of water and solid blocks. Fully submerged movement retains the swimming impulse.
- Generated item triangles now face outward, including the front/back texture faces and extruded edges.
- World pause no longer pauses the music voice. The existing music scheduler continues to advance.

Automated coverage: the unit suite checks one-block bank exits at three water depths, the submerged swimming impulse, and outward winding for all six faces of an extruded opaque item pixel.

Manual checks still needed on Windows and macOS:

1. Walk, attack, and use an item, then switch to another application. Typing, clicking, scrolling, and controller input outside MCDE must cause no new gameplay actions. Return to the game and check mouse capture, movement, and menus.
2. Jump toward a one-block bank from thin flowing water, mid-depth flowing water, and one-block source water. Repeat with low overhead clearance; the player must not pass through the ceiling. Check fully submerged swimming separately.
3. Inspect swords/tools in first person, third person, dropped form, and inventory. Check both broad faces and thin edges with both renderers.
4. Pause while music is playing, keep the menu open past the track's end, and verify the next track starts according to the configured music frequency. Repeat in singleplayer and multiplayer.

## Original pause blur assessment

The assessment below describes the old implementation. Its replacement and validation are documented in [PAUSE_BLUR.md](PAUSE_BLUR.md).

`PSBlur` in `shaders/world.hlsl` takes nine samples arranged in a cross. Both DirectX and Vulkan use nearest-neighbor sampling with wrapping. The strength setting increases the spacing of these same samples; it does not add coverage. This preserves hard pixel boundaries and produces separated image copies instead of a smooth broad blur. At the default setting the furthest sample is approximately nine screen pixels away; at maximum it is about sixteen.

Recommended design:

1. Give the blur its own bilinear, clamp-to-edge sampler so world textures can retain their current pixel-art filtering.
2. Filter the scene down to half or quarter resolution.
3. Run a horizontal Gaussian pass into an intermediate image, then a vertical pass using that intermediate result. This blends a full neighborhood instead of sampling only a cross in the original image.
4. Upscale with bilinear filtering, apply a subtle dark tint if desired, and draw the menu afterward so its text stays sharp.
5. Make strength control the effective screen-space blur width. Tune a substantially wider range by visual comparison across resolutions; increasing the existing nine-tap spacing is insufficient.

Filtered lower-resolution buffers and separable passes make a wide blur practical, though its final cost and quality need GPU measurements. Avoid unfiltered downsampling, which would reintroduce blockiness and shimmer. Frozen paused scenes could reuse the blurred result; live multiplayer backgrounds would need refreshes.

Reference: [NVIDIA GPU Gems, Real-Time Glow, sections 21.2.1–21.2.4](https://developer.nvidia.com/gpugems/gpugems/part-iv-image-processing/chapter-21-real-time-glow), covering filtered downsampling and separable blur passes.
