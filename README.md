# Tiny Control — Omarchy bar widget

A native [Omarchy](https://omarchy.org/) / Quickshell bar widget for **OBSBOT
Tiny 2 and Tiny 3 series** webcams — one widget for every connected camera. A
camera icon in the bar opens a popup with a camera picker, sleep/wake, AI
tracking and mode, the camera's presets, HDR, white balance, and a live preview.

Forked from Josh Lambert's
[omarchy-obsbot-tiny3](https://github.com/joshualambert/omarchy-obsbot-tiny3);
it is the front-end for [tiny-control](https://github.com/Geoff-Ilmax/tiny-control).

<p align="center">
  <img src="preview.png" alt="Tiny Control bar widget" width="360">
</p>

- **Camera picker** — choose any connected camera. The choice becomes
  `tinyctl`'s *selected* camera, so the keybindings and menu snippets that use
  `tinyctl -c selected …` act on the same camera. Until a camera is chosen the
  controls stay disabled; nothing acts on an implicit default.
- **Bar icon** — pulses while the selected camera is in use; left-click opens
  the popup, right-click toggles sleep, middle-click opens the live preview, all
  for the selected camera. The tooltip names it.
- **Tabs** — **Camera** (switches, tracking mode, presets, power-on preset,
  preview, and a **Remote notifications** switch for the OBSBOT remote), **Gimbal** (position, D-pad, zoom, fine control, axis swaps) and
  **Image** (hue, contrast, saturation and sharpness with −/+ in steps of 5,
  or 1 with Fine control, and a reset to the camera's defaults).
- **Popup** — switches for sleep/wake, AI tracking, HDR and auto white balance;
  a tracking-mode picker that only offers modes the camera's model supports;
  buttons for the camera's own presets 1–3 (named as in OBSBOT Center, power-on
  preset marked) and a **Power-on preset** picker on models where tinyctl's
  power-on copy is verified (the Tiny 2); a gimbal D-pad (▲ ◀ ⌖ ▶ ▼, 5° steps or
  1° with **Fine control**, **Swap left/right** and **Swap up/down** to invert an axis — all three saved per camera by tinyctl — within the camera's range; ⌖ recenters; disabled
  while AI tracking is steering, but available in Desk mode) and zoom −/+; a preview-resolution picker; and **Live preview** for the
  selected camera.

The popup polls the selected camera's real state once per second while open.
Switches reflect confirmed readback rather than an optimistic local value.
Commands run one at a time, wait for completion and surface errors in the
popup. The popup also reports whether `tiny-guard` is running.

Awake selects persistent keep-awake mode; Sleep remains authoritative even
during calls. **Wake automatically for calls** selects automatic wake for video
or microphone use. Saved tracking, HDR and white-balance choices are enforced
per camera by `tiny-guard`. Recalling a preset also applies its Additional
settings (tracking mode, image values, white balance) as OBSBOT Center does.

## Requirements

This widget is a front-end for the **tiny-control** CLI, **v0.2.0 or later**.
Install it first — see its README:
<https://github.com/Geoff-Ilmax/tiny-control>. The `tinyctl` and
`tiny-preview` commands must be on your `PATH`, and `tiny-guard.service` should
be enabled.

The live preview additionally uses [`mpv`](https://mpv.io/). This widget itself
installs nothing, runs no privileged commands, and writes no configuration of
its own — it only invokes `tinyctl` and `tiny-preview`, plus `systemctl
--user` for its **Settings guard** switch (enable/disable `tiny-guard.service`). (Choosing a camera runs
`tinyctl select`, which records the selection in tinyctl's own state file.)

Coming from the upstream widget (`io.github.joshualambert.obsbot-tiny3`)?
Remove that one first; this plugin has a different id and uses the renamed
`tinyctl` commands.

## Install

### A pinned release by hand

Every `v*` tag publishes an archive plus a `SHA256SUMS` file and a
[Sigstore build-provenance attestation](https://docs.github.com/actions/security-guides/using-artifact-attestations)
— see [**Releases**](https://github.com/Geoff-Ilmax/omarchy-tiny-control/releases).
The archive's root directory is the plugin id, so it extracts straight into your
plugins folder:

```bash
VER=2.0.0
REL=https://github.com/Geoff-Ilmax/omarchy-tiny-control/releases/download/v$VER

curl -fLO "$REL/omarchy-tiny-control-$VER.tar.gz"
curl -fLO "$REL/SHA256SUMS"
sha256sum --check --ignore-missing SHA256SUMS      # must print: OK

# optional: prove the archive came from this repo's release workflow
gh attestation verify "omarchy-tiny-control-$VER.tar.gz" \
  --repo Geoff-Ilmax/omarchy-tiny-control

mkdir -p ~/.config/omarchy/plugins
tar xzf "omarchy-tiny-control-$VER.tar.gz" -C ~/.config/omarchy/plugins/
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.geoff-ilmax.tiny-control
```

### From a git checkout

```bash
mkdir -p ~/.config/omarchy/plugins/io.github.geoff-ilmax.tiny-control
cp manifest.json Panel.qml README.md LICENSE preview.png \
   ~/.config/omarchy/plugins/io.github.geoff-ilmax.tiny-control/
omarchy-shell shell rescanPlugins     # make the shell notice a hand-copied plugin
omarchy plugin enable io.github.geoff-ilmax.tiny-control
```

### Add it to your bar

Put this entry in the `right` (or `left` / `center`) list under `bar.layout` in
`~/.config/omarchy/shell.json`:

```json
{ "id": "io.github.geoff-ilmax.tiny-control" }
```

and reload the shell:

```
omarchy restart shell
```

## Removal

Remove the `{ "id": "io.github.geoff-ilmax.tiny-control" }` entry from
`~/.config/omarchy/shell.json`, then:

```
omarchy plugin disable io.github.geoff-ilmax.tiny-control
omarchy plugin remove io.github.geoff-ilmax.tiny-control
omarchy restart shell
```

## Development

`./scripts/validate-plugin.sh .` runs the same manifest checks the Omarchy shell
enforces before it will load a plugin; CI runs it on every push, and the release
workflow runs it again before publishing. Releasing is documented in
[`RELEASING.md`](RELEASING.md).

## License

MIT — see [`LICENSE`](LICENSE). Part of the **tiny-control** project:
<https://github.com/Geoff-Ilmax/tiny-control>
