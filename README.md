# Digital Bard Dice

Digital Bard Dice is a Playdate dice roller for tabletop RPGs. It renders animated 3D-style dice with optional shaded fills, supports common D&D dice, and includes normal, advantage, and disadvantage roll modes.

## Features

- Animated wireframe or shaded dice preview
- D2 through D20 support
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
Digital_Bard_Dice.pdx/     Compiled package output
```

The source file is named `Digital_Bard_Dice.lua`, not `main.lua`, so build with `pdc -m`.

## Build

Requires the Playdate SDK and `pdc` on your `PATH`.

For a clean package build:

```sh
pdc -m -k Digital_Bard_Dice.lua Digital_Bard_Dice.pdx
```

The `-m` flag compiles `Digital_Bard_Dice.lua` as the main Lua file. The `-k` flag skips unrecognized files so the previously compiled `.pdx` folder is not copied into the new package.

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

These compile into the corresponding `.pdi` files inside `Digital_Bard_Dice.pdx/launcher`.

## Metadata

Current package metadata:

- Name: `Digital Bard Dice`
- Author: `Mathan Games`
- Bundle ID: `com.mathan.digitalbarddice`
- Version: `1.1`
- Build number: `4`
