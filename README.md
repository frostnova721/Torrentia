# Torrentia

## Introduction

Torrentia is a BitTorrent client primarily aimed at streaming torrent videos.

## Usage

If you want to test torrentia out, first clone the repo:

```bash
git clone https://github.com/frostnova721/Torrentia
cd Torrentia
```

Install dependencies (Required Dart >=3.6)

```bash
dart pub get
```

### Streaming

To start the streaming server from a torrent file, run:

```bash
dart run bin/torrentia.dart path/to/torrent-file.torrent
```

This should start a local server and print a player URL, which you can paste into a video player supporting network streams (like VLC)!
*OR*
The tool CLI also prints a web url, which you can open in browser for the playback

Additionally, you can try running with the flags:

- `--list`: list the files in the torrent
- `-f <index>`: stream a specific file (default: the largest video)

### Downloading

To download the torrent, run:

```bash
dart run bin/torrentia.dart  path/to/torrent-file.torrent --download
```

**seeding is optional and can only be enabled while on download mode, use the `--seed` flag to enable seeding**

## Test torrent

`assets/big-buck-bunny.torrent` is the torrent for *Big Buck Bunny* (© Blender Foundation, CC BY 3.0).

## License

Copyright (C) 2026 FrostNova

Torrentia is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0-only).

You are free to use, modify, and share it, but if you distribute a modified version **or run it as a network service**, you must make your source code available under the same license.

The test torrent in `assets/` is a third-party work and keeps its own license (see above).
