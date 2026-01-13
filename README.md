# Dreadpirate

Dreadpirate is a Turtle WoW (Vanilla 1.12) Warrior “one-button” rotation helper built around Theo-style logic: smart rage gating, early Sunder handling, and optional swing-timed Heroic Strike/Cleave weaving.

> Note: The current code announces itself in chat as **“QuickTheoWarrior loaded!”** and lists the supported commands on login. :contentReference[oaicite:1]{index=1}  
> If your folder/addon name is **Dreadpirate**, that’s totally fine — you can keep the branding in your `.toc` while the internal print strings still say QuickTheoWarrior.

---

## Features

### Rotations / Modes
- **/qhtwarrior** – main Warrior rotation driver (the “default” mode). :contentReference[oaicite:2]{index=2}  
- **/theofury** – Fury DW rotation variant (no Execute / no Overpower) for more conservative trash-style play. :contentReference[oaicite:3]{index=3}  
- **/theoprotect** – Protection rotation driver. :contentReference[oaicite:4]{index=4}  
- **/theoarms** – Arms rotation driver. :contentReference[oaicite:5]{index=5}  
- **/theotrash** – trash helper mode. :contentReference[oaicite:6]{index=6}  
- **/theo2hfury** – 2H Fury Slam-weave module (loaded from a second file; see below). :contentReference[oaicite:7]{index=7}

### Toggles
- **/theocleave** – switches weaving spend between **Cleave** and **Heroic Strike**. :contentReference[oaicite:8]{index=8}  
- **/theomsmode** – toggles **Master Strike + Pummel** behavior. :contentReference[oaicite:9]{index=9}  
- **/theoop** – toggles baked-in **Overpower** usage (stance-dance logic). :contentReference[oaicite:10]{index=10}  
- **/theosundermaint** – enables/disables ONLY the Sunder maintenance macro behavior. :contentReference[oaicite:11]{index=11}  
- **/weaponx** – PvP mode toggle. :contentReference[oaicite:12]{index=12}  

### Movement Helper
- **/theostance** then **/theocharge** – stance+gap-closer helper (Charge/Intercept/Intervene logic). :contentReference[oaicite:13]{index=13}  

---

## Requirements / Recommended

- **Turtle WoW** client (Vanilla 1.12-based).
- Recommended: **SP_SwingTimer** (or any addon exposing `st_timer`) if you want swing-timed weaving / slam-fit checks.  
  The 2H module explicitly uses `st_timer` for “can the Slam fit before the next white swing?” logic. :contentReference[oaicite:14]{index=14}  
  The Fury “no-exec” weaver is also written to use SP_SwingTimer timing. :contentReference[oaicite:15]{index=15}

Melee-range checks are done using interact distance checks (`CheckInteractDistance`). :contentReference[oaicite:16]{index=16}

---

## Installation

1. Download / clone the repo.
2. Place the folder in:
