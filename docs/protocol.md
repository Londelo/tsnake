# tsnake `--protocol` — the stdin/stdout contract

`snake --protocol` speaks NDJSON over a pipe: one flat JSON object per line each
way, newline-terminated, no nesting, no array values except inside a frame. The
parser is deliberately dumb (substring-locate the key, read past the colon):
anything unparseable is "not a command" and is ignored — a half-written line from
the shell must never hang or kill a live game. The engine's clock is its own; the
client never drives ticks.

## Command grammar (stdin → engine)

```
line      := command "\n" ;
command  := object ;                    (* unparseable or unknown ⇒ ignored *)
object    := "{" member ("," member)* "}" ;
member    := "\"cmd\"" ":" string | pair ;
pair      := "\"dx\"" ":" int | "\"dy\"" ":" int
           | "\"x\""  ":" int | "\"y\""  :  int
           | "\"on\"" ":" int                    (* wrap, absolute form *)
           | "\"ms\"" ":" int                    (* speed, optional key *)
           | "\"w\""  ":" int | "\"h\"" ":" int ;
```

Keyed members are located by first substring match and parsed with `strtol`, so a
misplaced key is simply not found (the command is then refused or ignored).
`dx`+`dy` must be exactly one non-zero component of ±1 (diagonals and zeros are
nothing). A line longer than the 255-byte read buffer is dropped whole — same
"ignore and keep playing" as an unknown `cmd`.

## Accepted commands

| `cmd` | keys | gate / effect |
|---|---|---|
| `dir` | `dx`, `dy` | only after START; sets `hunt=0` (steering takes the wheel) and queues the lean (reversals/no-ops filtered in `queue_direction`) |
| `click` | `x`, `y` (board coords) | legal BEFORE START; toggles a token (the `remove` key in some client drafts is **not** parsed — a second click on the same cell is the remove); does NOT cancel hunt, it aims it |
| `pause` | — | `if (started && alive)` toggle |
| `wrap` | optional `on` (0/1) | refused once STARTed; absolute with `on`, else toggle; saves setup |
| `speed` | `ms` (or `"speed"` alone) | refused once STARTed; `ms` **missing ⇒ refused**; clamped 20..200; saves setup |
| `start` | — | sets `started=1`, clears `paused` and the `pending` queue |
| `hunt` | — | only after START; toggle; clears `pending` |
| `restart` | — | banks `len` to the file first; keeps `started`/`wrap`/`tick_ms` across `game_init` |
| `size` | `w`, `h` | clamped to 10..400 × 6..250; `sanitize_after_resize` (never a state reset) |
| `flush` | — | redundancy flush of both state files, then answer |
| `quit` | — | bank + flush + stop (`handle_command` returns 0; `main` prints the final length) |

## Frame shape (stdout ← engine)

One snapshot per line, always complete (never diffed), `body` head-first:

```json
{"event":"frame","tick":N,"w":W,"h":H,"alive":A,"paused":P,"wrap":R,"hunt":U,
 "started":S,"speed":MS,"flash":F,"len":L,"best":B,"dir":[DX,DY],
 "head":{"x":X,"y":Y},
 "body":[{"x":..,"y":..},..],
 "wound":[{"x":..,"y":..,"ttl":T},..],
 "food":[{"x":..,"y":..,"placed":0|1},..]}
```

Every field is engine truth (`best` is the record as it stands **on disk**, so a
frame can never report a number the file does not hold; `speed` is `tick_ms`).
A frame is written on a tick, and immediately after any accepted command, so a
client that misses one can repaint from the next. A `write`/`fflush` failure —
reader gone — ends the engine: a self-ticking emitter pouring into a closed pipe
would run invisibly for the rest of the session.

## argv

`--protocol`, `--square-cells`, `--size WxH` (10..400 × 6..250, clamped),
`--state PATH`, `--setup PATH`. Square cells make every stride one cell (see
`stride_len_for`). Unknown flag ⇒ usage on stderr, exit 2.
