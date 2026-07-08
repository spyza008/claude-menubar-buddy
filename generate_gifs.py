#!/usr/bin/env python3
"""Generate animated panda GIFs for Claude Menu Bar Buddy from the same
pixel-art grids used in the M5StickC Plus2 firmware (src/buddies/panda.cpp)."""

from PIL import Image, ImageDraw, ImageFont

PPX = 8  # pixels per art-cell, bigger than the M5Stick version since this
         # renders in a menu dropdown, not a tiny 135px screen

BASE = [
    "...KK......KK...", "..KKKK....KKKK..", "..KKKK....KKKK..",
    "...WWWWWWWWWW...", "..WWWWWWWWWWWW..", ".WWWKKW..WKKWWW.",
    ".WWWKKW..WKKWWW.", ".WWWWWWWKKWWWWW.", ".WWWWWWWWWWWWWW.",
    "..WWWWWWWWWWWW..", "..WWWWWWWWWWWW..", ".WWWWWWWWWWWWWW.",
    ".WWWWWWWWWWWWWW.", "KWWWW......WWWWK", "KKWWW......WWWKK",
    "..KK........KK..",
]
BLINK = [
    "...KK......KK...", "..KKKK....KKKK..", "..KKKK....KKKK..",
    "...WWWWWWWWWW...", "..WWWWWWWWWWWW..", ".WWWKKW..WKKWWW.",
    ".WWWWWW..WWWWWW.", ".WWWWWWWKKWWWWW.", ".WWWWWWWWWWWWWW.",
    "..WWWWWWWWWWWW..", "..WWWWWWWWWWWW..", ".WWWWWWWWWWWWWW.",
    ".WWWWWWWWWWWWWW.", "KWWWW......WWWWK", "KKWWW......WWWKK",
    "..KK........KK..",
]
WIDE = [
    "...KK......KK...", "..KKKK....KKKK..", "..KKKK....KKKK..",
    "...WWWWWWWWWW...", "..WWWWWWWWWWWW..", ".WWKKKW..WKKKWW.",
    ".WWKKKW..WKKKWW.", ".WWKKKW..WKKKWW.", ".WWWWWWWKKWWWWW.",
    "..WWWWWWWWWWWW..", "..WWWWWWWWWWWW..", ".WWWWWWWWWWWWWW.",
    ".WWWWWWWWWWWWWW.", "KWWWW......WWWWK", "KKWWW......WWWKK",
    "..KK........KK..",
]
# 5-hour-limit mood states: same body, progressively more-closed eyes.
TIRED = [  # half-lidded — top of eye droops shut, pupil still peeking below
    "...KK......KK...", "..KKKK....KKKK..", "..KKKK....KKKK..",
    "...WWWWWWWWWW...", "..WWWWWWWWWWWW..", ".WWWWWWW..WWWWWW.",
    ".WWWKKW..WKKWWW.", ".WWWWWWWKKWWWWW.", ".WWWWWWWWWWWWWW.",
    "..WWWWWWWWWWWW..", "..WWWWWWWWWWWW..", ".WWWWWWWWWWWWWW.",
    ".WWWWWWWWWWWWWW.", "KWWWW......WWWWK", "KKWWW......WWWKK",
    "..KK........KK..",
]
SLEEPY = [  # eyes fully shut, still upright
    "...KK......KK...", "..KKKK....KKKK..", "..KKKK....KKKK..",
    "...WWWWWWWWWW...", "..WWWWWWWWWWWW..", ".WWWWWWW..WWWWWW.",
    ".WWWWWWW..WWWWWW.", ".WWWWWWWKKWWWWW.", ".WWWWWWWWWWWWWW.",
    "..WWWWWWWWWWWW..", "..WWWWWWWWWWWW..", ".WWWWWWWWWWWWWW.",
    ".WWWWWWWWWWWWWW.", "KWWWW......WWWWK", "KKWWW......WWWKK",
    "..KK........KK..",
]
ASLEEP = SLEEPY  # same face; Zzz + no bounce is what sells "asleep" (added at render time)

COLORS = {"K": (132, 136, 140, 255), "W": (255, 255, 255, 255),
          "P": (255, 77, 148, 255), ".": (0, 0, 0, 0)}


def render(grid, yoff=0, zzz_offset=None):
    w = max(len(r) for r in grid) * PPX
    h = len(grid) * PPX
    # Leave headroom above the sprite for a drifting "Z" when asleep.
    pad_top = 24 if zzz_offset is not None else 0
    img = Image.new("RGBA", (w, h + pad_top), (0, 0, 0, 0))
    px = img.load()
    for r, row in enumerate(grid):
        for c, ch in enumerate(row):
            color = COLORS.get(ch, (0, 0, 0, 0))
            if color[3] == 0:
                continue
            y0 = r * PPX + yoff + pad_top
            for dy in range(PPX):
                yy = y0 + dy
                if yy < 0 or yy >= h + pad_top:
                    continue
                for dx in range(PPX):
                    px[c * PPX + dx, yy] = color
    if zzz_offset is not None:
        d = ImageDraw.Draw(img)
        try:
            font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 16)
        except Exception:
            font = ImageFont.load_default()
        dx, dy = zzz_offset
        d.text((w - 34 + dx, 2 + dy), "Z", font=font, fill=(180, 200, 255, 230))
    return img


def save_gif(frames, durations, path):
    frames[0].save(path, save_all=True, append_images=frames[1:],
                    duration=durations, loop=0, disposal=2)


# Idle: blink cycle
idle_frames = [render(BASE), render(BASE), render(BASE), render(BLINK), render(BASE), render(BASE)]
save_gif(idle_frames, [500, 500, 500, 150, 500, 500], "Sources/ClaudeMenuBarBuddy/Resources/buddy_idle.gif")

# Pending/attention: wide eyes + little bounce
pend_frames = [render(WIDE, 0), render(WIDE, -2), render(WIDE, 0), render(WIDE, -2)]
save_gif(pend_frames, [250, 250, 250, 250], "Sources/ClaudeMenuBarBuddy/Resources/buddy_pending.gif")

# 5-hour-limit moods: tired (half-lidded, still bounces a little), sleepy
# (eyes shut, slower bounce), asleep (eyes shut, no bounce, Zzz drifting up).
tired_frames = [render(TIRED, 0), render(TIRED, -1)]
save_gif(tired_frames, [600, 600], "Sources/ClaudeMenuBarBuddy/Resources/buddy_tired.gif")

sleepy_frames = [render(SLEEPY, 0), render(SLEEPY, -1)]
save_gif(sleepy_frames, [900, 900], "Sources/ClaudeMenuBarBuddy/Resources/buddy_sleepy.gif")

asleep_frames = [
    render(ASLEEP, 0, zzz_offset=(0, 6)),
    render(ASLEEP, 0, zzz_offset=(3, 0)),
    render(ASLEEP, 0, zzz_offset=(6, -6)),
]
save_gif(asleep_frames, [500, 500, 500], "Sources/ClaudeMenuBarBuddy/Resources/buddy_asleep.gif")

print("Wrote buddy_idle.gif, buddy_pending.gif, buddy_tired.gif, buddy_sleepy.gif, buddy_asleep.gif")
