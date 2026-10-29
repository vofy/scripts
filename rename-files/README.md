# rename-files

Batch-renames files in the current directory. It can clean up WhatsApp image names, change their date, and renumber any numbered series so the numbering has no gaps.

## Quick start

Run it from the folder that holds the files:

```bash
curl -fsSL https://raw.githubusercontent.com/vofy/scripts/main/rename-files/rename-files.sh | bash -s -- -w -r
```

Everything after `--` goes to the script. Pipe it to **`bash`**, not `sh`.

Or from a local copy:

```bash
chmod +x rename-files.sh
./rename-files.sh -w -r                          # IMG-20231025-WA0007.jpg -> IMG-20231025-0000.jpg
./rename-files.sh -d 20240101                    # IMG-20231025-... -> IMG-20240101-...
./rename-files.sh -r -p '*.mp4'                  # "Holiday (7).mp4" -> Holiday_0000.mp4
```

## Options

| Option | Default | Meaning |
|---|---|---|
| `-w`, `--remove-wa` | | Remove `WA` from the filename |
| `-d`, `--date STRING` | | Replace the 8-digit date after `IMG-` with `STRING` |
| `-r`, `--renumber` | | Renumber from `0000` and close gaps |
| `-p`, `--pattern GLOB` | `IMG-*` | Files to process. Quote it so your shell doesn't expand it |
| `-h`, `--help` | | Show help |

## Renumbering

Files are sorted in natural order (`(2)` before `(10)`) and numbered from `0000`. The extension is kept. The script recognises three index styles:

| Before | After |
|---|---|
| `IMG-20231025-WA0007.jpg` | `IMG-20231025-0000.jpg` (everything after the last `-` is the index) |
| `Holiday_0007.mp4` | `Holiday_0000.mp4` |
| `Holiday (7).mp4` | `Holiday_0000.mp4` |

All matched files share one counter. To number separate series on their own, run the script once per series with a narrower `-p`, for example `-p 'Holiday*'`.

The script never overwrites a file. If the new name already exists, it prints a warning and skips that file. Running it twice changes nothing the second time.
