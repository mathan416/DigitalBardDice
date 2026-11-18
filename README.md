# Digital Bard Dice

Digital Bard Dice is a Playdate dice roller for tabletop RPGs. It renders animated 3D-style dice with optional shaded fills, supports common D&D dice, and includes normal, advantage, and disadvantage roll modes.

## Features

- Animated shaded dice preview (shaded by default, with a wireframe option)
- Any die from D2 to D20 (non-standard sizes are previewed with the nearest standard die shape)
- Quick switching between common dice: D4, D6, D8, D10, D12, D20
- Normal, advantage, and disadvantage roll modes
- Smooth roll animation with a longer natural deceleration curve
- Persistent settings for die size, roll mode, last result, and shading
- Launcher assets included for Playdate packaging

## Controls

On the title screen:

- `A`: enter the dice roller
- `B`: toggle shaded fills
- System menu `Shading`: toggle shaded fills

In the dice roller:

- `A`: roll
- `B`: cycle roll mode: normal, advantage, disadvantage
- `Left` / `Right`: decrease or increase sides by 1
- `Up` / `Down`: jump through common dice

On the result screen:

- `A`: roll again
- `B`: cycle roll mode
- `Left` / `Right` / `Up` / `Down`: change die and return to idle preview

## Project Layout

```text
Digital_Bard_Dice.lua      Main game source
pdxinfo                    Playdate package metadata
launcher/                  Source launcher images
build/                     Generated package and sideload ZIP
```

The source file is named `Digital_Bard_Dice.lua`, not `main.lua`, so build with `pdc -m`.

## Build

Requires the Playdate SDK and `pdc` on your `PATH`.

For a clean package build:

```sh
sh build.sh
```

The script builds from an isolated staging directory, compiling `Digital_Bard_Dice.lua` as the main Lua file. Upload the ZIP to your Playdate account's sideload page, or copy the `.pdx` package to the device's `Games` folder while it is in data disk mode.

For a temporary compile check:

```sh
pdc -m -k Digital_Bard_Dice.lua /private/tmp/Digital_Bard_Dice_check.pdx
```

## Launcher Assets

`pdxinfo` uses:

```text
imagePath=launcher
```

The launcher image set is present:

- `launcher/image.png`
- `launcher/launchImage.png`
- `launcher/icon.png`
- `launcher/card.png`

These compile into the corresponding `.pdi` files inside `build/Digital_Bard_Dice.pdx/launcher`.

## Metadata

Current package metadata:

- Name: `Digital Bard Dice`
- Author: `Mathan Games`
- Bundle ID: `com.mathan.digitalbarddice`
- Version: `1.1`
- Build number: `6`
