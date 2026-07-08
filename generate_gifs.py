#!/usr/bin/env python3
"""Generate animated panda GIFs for Claude Menu Bar Buddy from the same
pixel-art grids used in the M5StickC Plus2 firmware (src/buddies/panda.cpp)."""

from PIL import Image, ImageDraw

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

COLORS = {"K": (132, 136, 140, 255), "W": (255, 255, 255, 255),
          "P": (255, 77, 148, 255), ".": (0, 0, 0, 0)}


def render(grid, yoff=0):
    w = max(len(r) for r in grid) * PPX
    h = len(grid) * PPX
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = img.load()
    for r, row in enumerate(grid):
        for c, ch in enumerate(row):
            color = COLORS.get(ch, (0, 0, 0, 0))
            if color[3] == 0:
                continue
            y0 = r * PPX + yoff
            for dy in range(PPX):
                yy = y0 + dy
                if yy < 0 or yy >= h:
                    continue
                for dx in range(PPX):
                    px[c * PPX + dx, yy] = color
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

print("Wrote buddy_idle.gif and buddy_pending.gif")
