#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
stage_dir=$(mktemp -d "${TMPDIR:-/tmp}/digital-bard-dice.XXXXXXXX")
trap 'rm -rf "$stage_dir"' EXIT HUP INT TERM

cp "$project_dir/Digital_Bard_Dice.lua" "$project_dir/pdxinfo" "$stage_dir/"
cp -R "$project_dir/launcher" "$stage_dir/launcher"
pdc -m -k "$stage_dir/Digital_Bard_Dice.lua" "$stage_dir/Digital_Bard_Dice.pdx"
(cd "$stage_dir" && COPYFILE_DISABLE=1 zip -X -qr Digital_Bard_Dice.zip Digital_Bard_Dice.pdx)

mkdir -p "$project_dir/build"
rm -rf "$project_dir/build/Digital_Bard_Dice.pdx"
cp -R "$stage_dir/Digital_Bard_Dice.pdx" "$project_dir/build/Digital_Bard_Dice.pdx"
cp "$stage_dir/Digital_Bard_Dice.zip" "$project_dir/build/Digital_Bard_Dice.zip"
