# Arturia MicroFreak preset taxonomy & where MCC stores it

Confirmed 2026-09-01 from a MIDI Control Center screenshot (device disconnected,
so every value below is read from local files, not the hardware).

## Types (category — exactly one per preset)

Bass, Brass, Keys, Lead, Organ, Pad, Percussion, Sequence, SFX, Strings,
Template, Vocoder  — 12 values. (Arturia's website surfaces "Percussion" as
"Drums" and "SFX" as "Sound Effects"; treat those as display aliases.)

## Characteristics (tags — zero or more per preset)

Acid, Aggressive, Ambient, Bizarre, Bright, Complex, Dark, Digital, Ensemble,
Funky, Hard, Long, Noise, Quiet, Short, Simple, Soft, Soundtrack — 18 values.

These are the tag vocabulary for the librarian. Free-form tags may be layered
on top, but the Arturia set is the canonical one shown as filter chips.

## Where MCC stores this

MCC keeps no separate database. Everything is `.mbp` files:

- Working projects live under
  `/Library/Arturia/MIDI Control Center/Templates/MicroFreak/Local/User/<Project>/`,
  one `.mbp` per slot (filename is slot-numbered, e.g. `226-…-A226.mbp`).
- "Likes" / ratings are just smart folders of `.mbp` copies
  (`5.0 Likes/`, `4.0 Likes/`, …).
- Type + Characteristics ride inside each `.mbp`'s 9-byte metadata field
  (the `18`-hex-char token before the 4672-byte blob). A downloaded pack that
  was never categorized has all-zero meta (e.g. Ambient Peaks); a categorized
  project (e.g. Clockwork Nocturnal) has non-zero meta.

## The full MCC store (import source of record)

`…/Local/User/` holds the user's entire MCC library — **983 real presets,
941 unique by blob** — across:

- **`10042023 16h06`** — a 491-preset project: effectively a full-device dump
  from 2023-10-04 (near all 512 slots). This is the user's own MicroFreak
  state, not a commercial pack.
- **16 commercial banks** (Arp Monster, Back To The 80s, Voltage Forms, Tokyo
  88, …) — 32 presets each.
- **Smart folders** `5.0 Likes` / `4.0 Likes` / `3.0 Likes` / `All Custom
  Patches` — not new presets (0 unique-only), but they encode **user ratings**:
  a preset's presence in `N.0 Likes` = an N-star rating. Use this to
  auto-populate favorites (5.0 → favorite) and a rating attribute.

Import plan: dedupe by blob → 941 library entries; per entry capture **origin**
(originating project/bank name(s), slot number from filename) and **rating**
(from the Likes folders); preserve the raw 9-byte meta for future characteristic
decode. Each of the 17 projects (incl. the device dump) also becomes a
Collection. 138 unique presets carry non-zero meta (are Arturia-tagged).

## Meta-byte encoding — PARTIALLY decoded (do not ship a full decoder yet)

Across 545 real presets in the Music Production banks, every one of the 9 meta
bytes only ever takes values {0, 1, 16, 17} — i.e. only bit0 (0x01) and bit4
(0x10) are ever set. That is **18 boolean slots** (9 bytes × 2 bits), matching
the 18 Characteristics exactly. Only ~96 of 545 presets carry any flags
(449 are untagged; tagged ones most often have 3 flags).

Solid deduction so far: `byte[5] bit0` is shared by all five labeled
Percussion+Dark presets from the screenshot → it corresponds to **Dark**.
The remaining slot→characteristic map and the location of **Type** are NOT yet
resolved (the 5 available labels, all Percussion+Dark, underdetermine it, and
From Detroit's flag count is one short of Type+3-chars, suggesting Type is not a
19th flag here). **Decision:** the app treats Type/Characteristics as editable
attributes using the exact vocabulary above; it does NOT auto-decode the meta
bits until the mapping is proven against ≥~20 labeled presets spanning several
Types. Getting that labeled set (read Types/Characteristics off MCC for known
presets) is the unlock for automatic import-time tagging.
