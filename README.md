# mpv-jelly-sync

An [mpv](https://mpv.io) script that reports local playback back to a [Jellyfin](https://jellyfin.org) server. Play files from a network share (SMB/NFS) in plain mpv, and Jellyfin still marks them watched and remembers where you stopped.

This is **not** a Jellyfin client. It doesn't stream from Jellyfin or add any menus. It only watches what mpv plays and tells Jellyfin about it.  I had Claude write it because I often watch stuff on my desktop via MPV because I find it easier to jump around things, but then obviously Jellyfin couldn't track it.

## Requirements

- mpv 0.38 or newer
- `curl`
- Linux (written for Linux; other platforms are untested)
- Your media must already be in a Jellyfin library

## Install

```sh
cp scripts/mpv-jelly-sync.lua ~/.config/mpv/scripts/
cp script-opts/mpv-jelly-sync.conf ~/.config/mpv/script-opts/
```

Then edit `~/.config/mpv/script-opts/mpv-jelly-sync.conf`:

1. Set `url` and `username`.
2. Put your password alone in the file named by `password_file`, and lock it down:
   ```sh
   chmod 600 ~/.config/mpv/jellyfin_password
   ```
   You can set the `JELLYFIN_PASSWORD` environment variable instead.
3. Set `path_map` (see below).

## Path mapping

Jellyfin stores file paths as it sees them (often inside a container), which usually differ from where your computer mounts the share. `path_map` translates between them:

```
path_map=/mnt/Media/Movies=>/mnt/movies;/mnt/Media/TV Shows=>/mnt/tv
```

- Format is `local=>jellyfin`, with multiple pairs separated by `;`.
- The left side is the path as mpv sees the file on your computer.
- The right side must match the path shown in Jellyfin exactly (case-sensitive).
- Spaces in paths are fine. The longest matching prefix wins.

## Options

| Option | Default | Description |
|---|---|---|
| `url` | | Jellyfin base URL |
| `username` | | Jellyfin user to report as |
| `password_file` | | File containing the password (or use `JELLYFIN_PASSWORD`) |
| `path_map` | | Local-to-Jellyfin path translation, see above |
| `sync_progress` | `no` | `no`: only mark items watched. `yes`: full sync of start, progress, pause/seek and stop, so Jellyfin tracks your resume position and shows a live session in the Dashboard |
| `progress_interval` | `10` | Seconds between progress reports (full sync only) |
| `watched_threshold` | `90` | Percent played that counts as watched (`sync_progress=no` only) |
| `request_timeout` | `5` | Per-request timeout in seconds |

In the default mode nothing appears in the Dashboard. The only visible effect is the watched checkmark, and only after you reach the end of a file or pass `watched_threshold`.

## Checking that it works

Run mpv from a terminal with more logging:

```sh
mpv --msg-level=mpv-jelly-sync=v "/path/to/file.mkv"
```

You should see `logged in to Jellyfin` and then either a match or `no Jellyfin item with path ...`. On a miss the log also lists similar paths from Jellyfin, which usually points straight at a wrong `path_map` entry.

Optionally bind a key in `~/.config/mpv/input.conf` to check the current file on screen:

```
F9 script-binding mpv-jelly-sync/status
```

## How it works

- On first use the script lists the paths of all video items in your library, caches them in `~/.local/state/mpv/mpv-jelly-sync-cache.json`, and looks files up there. The cache refreshes daily, or when a file isn't found (at most every 5 minutes).
- It logs in with your username and password. Requests go to curl over stdin, so the password and token never appear in the process list.
- Files that aren't local paths (URLs, streams) are ignored.

## How it shows up in Jellyfin

The script logs in as client `mpv-jelly-sync`, with your computer's hostname as the device name and a device ID of `mpv-jelly-sync-<hostname>`. In Dashboard > Devices you'll see one entry per computer, so several machines won't collide as long as their hostnames differ. Two computers with the same hostname would share a device ID and log each other out.

## Security notes

- The password is sent to your Jellyfin server when the script logs in. Use an `https://` URL unless the connection is on a network you trust.
- The password and token are passed to curl over stdin, never as command-line arguments, so they don't show up in the process list.
- The path cache (`~/.local/state/mpv/mpv-jelly-sync-cache.json`) holds the file paths from your Jellyfin library. It contains no credentials, but treat it like any other file listing. Delete it any time and it will be rebuilt.
- With `--msg-level=mpv-jelly-sync=v` the log can include Jellyfin file paths. Keep that in mind before sharing logs.

## Limitations

- It reports progress but doesn't start playback from Jellyfin's saved resume position.
- API keys aren't supported. The script logs in with a username and password so playback is attributed to that user.

## License

MIT — see [LICENSE](./LICENSE).
