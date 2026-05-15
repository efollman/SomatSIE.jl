# SomatSIE.jl — Julia API Reference

`SomatSIE` is a thin, idiomatic Julia wrapper around
[libsie-z](https://github.com/efollman/libsie-z) (provided by `libsie_jll`)
for reading HBM/Somat eDAQ SIE acquisition files.

The public API is intentionally small and is organized around a single
top-level type — [`SieFile`](#siefile) — plus value/metadata types
(`Test`, `Channel`, `Dimension`, `Tags`) and the `SieError` exception.
Files are opened with [`opensie`](#siefile); dimension values are exposed via `dim.vec` (alias `dim.data`).

> The libsie 0.3 ABI is **read-only**: there is no SIE writer.

> The `Spigot` / `Output` block-iteration layer is implemented but kept
> internal. It is reachable as `SomatSIE.spigot` / `SomatSIE.Output` for
> advanced use, but is not part of the stable exported surface.

> Public accessors on `SieFile`, `Test`, `Channel`, and `Dimension` are
> exposed as **dot properties** \u2014 `f.tests`, `t.channels`,
> `ch.dims`, `dim.id`, `ch.name`, `x.tags`, etc. There are no
> matching exported functions; use the property syntax everywhere.

---

## Table of Contents

- [Errors](#errors)
- [`SieFile`](#siefile)
- [`Test`](#test)
- [`Channel`](#channel)
- [`Dimension`](#dimension)
- [`Tags`](#tags)
- [Reading data](#reading-data)
- [Quick reference: exported names](#quick-reference-exported-names)

---

## Errors

### `SieError <: Exception`

Thrown when a libsie call returns a non-zero status code.

Fields:

| Field     | Type     | Meaning                                                         |
|-----------|----------|-----------------------------------------------------------------|
| `code`    | `Int`    | Numeric libsie status code.                                     |
| `message` | `String` | Human-readable description from `sie_status_message`.           |

`Base.showerror` prints as `SieError(<code>): <message>`.

---

## `SieFile`

The opened-file handle. Mutable; closed automatically by the do-block
form of [`opensie`](#opening-a-file-opensie) (or its finalizer).

### Opening a file: `opensie`

```julia
opensie("myfile.sie") do f
    for t in f.tests, ch in t.channels
        @show ch.name
    end
end
```

The do-block form guarantees `close` runs even on exceptions \u2014 use it
for all file access.

### `close(file::SieFile)`

Release the underlying libsie file handle. **Idempotent.** After closing,
all borrowed `Test` / `Channel` / `Dimension` / `Tag` references owned by
the file become invalid.

### `isopen(file::SieFile) -> Bool`

`true` while the underlying libsie handle is live.

### `file.tests -> Vector{Test}`

All tests in the file, materialized into a `Vector`. Use `length` to get
a count. Channels live under tests — there is no `file.channels`
because channel ids may collide between tests; iterate via
`[ch for t in f.tests for ch in t.channels]`.

### `file.tags -> Tags`

File-level tag dictionary (see [`Tags`](#tags)).

---

## `Test`

A test (acquisition session) within a `SieFile`. Borrowed from the file —
do not use after the file is closed.

> Named `Test` for SIE convention. Reference as `SomatSIE.Test` to avoid
> clashing with `Base.Test`.

### `test.id -> Int`

**1-based** test id. Note: this differs from the libsie/file 0-based
convention — Julia code is uniformly 1-based.

### `test.channels -> Vector{Channel}`

All channels owned by the test, as a `Vector`. Use `length` for a count.

### `findchannel(test::Test, name::AbstractString) -> Union{Channel, Nothing}`

Look up a channel within `test` by its name. Exact, case-sensitive match.
Returns `nothing` if no channel has that name; if multiple channels
share the name, the first one is returned.

### `test.tags -> Tags`

Test-level tag dictionary.

---

## `Channel`

A data series within a `SieFile`. Borrowed from the file.

### `ch.id -> Int`

**1-based** channel id (unique within its `Test`). Note: this differs
from the libsie/file 0-based convention — Julia code is uniformly
1-based.

### `ch.name -> String`

Channel name.

### `ch.dims -> Vector{Dimension}`

All dimensions ("columns") of the channel, as a `Vector`. Use `length`
for a count. For a sequential time-history channel this is typically
length 2 (`dim.id == 1` is time, `dim.id == 2` is value); CAN channels
can have mixed numeric + raw dimensions.

### `ch.tags -> Tags`

Channel-level tag dictionary.

### `ch.schema -> Union{String, Vector{UInt8}, Nothing}`

Convenience accessor for the `core:schema` tag, or `nothing` if the tag
is absent. Equivalent to `get(ch.tags, "core:schema", nothing)`. The
schema string identifies the channel's data shape (e.g. `"timhis"`,
`"can_raw"`, `"msglog"`).

### `ch.sr -> Float64`

Convenience accessor for the `core:sample_rate` tag parsed as `Float64`.
Returns `NaN` when the tag is missing or unparseable.

```julia
for t in f.tests, ch in t.channels
    ch.schema == "timhis" || continue
    rate = ch.sr                        # Float64 (or NaN)
    @show ch.name, rate
end
```


### Additional channel convenience properties

All of the following are available on both libsie-backed and in-memory channels:

- `ch.description` → `core:description` tag (string; `""` when missing)
- `ch.datatype` → `data_type` tag (string; `""` when missing)
- `ch.filtfreq` → `somat:digital_filter_attenuation_frequency` parsed as `Float64` (`NaN` when missing/unparseable)
- `ch.filttype` → `somat:digital_filter_type` tag
- `ch.rangemin` / `ch.rangemax` → `somat:physical_range_min` / `somat:physical_range_max` as `Float64`
- `ch.eunits` → `somat:electrical_units` tag
- `ch.erangemin` / `ch.erangemax` → electrical min/max as `Float64`
- `ch.time` / `ch.data` → convenience dimensions for time-history channels (`timhis` or sequential `time_history`), otherwise empty `Float64[]`

---

## `Dimension`

A single axis ("column") of a `Channel`. Borrowed from the channel.

### `dim.id -> Int`

**1-based** dimension identifier (1 is typically time, 2 is value for
sequential time-series channels). Note: this differs from the libsie/file
0-based convention — Julia code is uniformly 1-based.

### `dim.tags -> Tags`

Per-dimension tag dictionary.

### `dim.vec -> AbstractVector`

Primary data vector for the dimension. This is the canonical property to use
when you want the full series as a vector.

### `dim.data -> AbstractVector`

Alias of `dim.vec` (same object for in-memory dimensions).

### `dim.label -> String`

Convenience accessor for `core:label`; empty string when absent.

### `dim.units -> String`

Convenience accessor for `core:units`; empty string when absent.

### `dim.description -> String`

Convenience accessor for `core:description`; empty string when absent.

---

## `Tags`

`Tags` is a type alias for `Dict{String, Union{String, Vector{UInt8}}}`.
Reading `x.tags` on a `SieFile`, `Test`, `Channel`, or `Dimension`
returns one of these dictionaries, fully materialized from the libsie
tag list.

Values are `String` for textual tags or `Vector{UInt8}` for binary blobs
— dispatch on the result type when needed.

Use the standard `Dict` API:

| Operation                     | Result                                                    |
|-------------------------------|-----------------------------------------------------------|
| `length(tags)`                | Number of tags.                                           |
| `iterate(tags)`               | Yields `key => value` pairs.                              |
| `tags[k::AbstractString]`     | Keyed access — returns the value or throws `KeyError`.    |
| `get(tags, k, default)`       | Keyed access with a fallback value.                       |
| `haskey(tags, k)`             | Membership test by key.                                   |
| `keys(tags)` / `values(tags)` | Standard `Dict` views.                                    |

```julia
ts = ch.tags
sr = get(ts, "core:sample_rate", nothing)
units = haskey(ts, "core:units") ? ts["core:units"] : ""
```

---

## Reading data

`Dimension` is an `AbstractVector`, and the full vector is exposed as
`dim.vec` (alias `dim.data`).

| Idiom                       | What it returns                                   | Notes                                |
|-----------------------------|---------------------------------------------------|--------------------------------------|
| `length(dim)` / `size(dim)` | sample count                                      | vector length                        |
| `eltype(dim)`               | `Float64` or `Vector{UInt8}`                      | column element type                  |
| `dim[i]`                    | one sample                                        | standard vector indexing             |
| `dim[a:b]`                  | sub-range vector                                  | standard range indexing              |
| `dim.vec` / `dim.data`      | full backing vector                               | preferred full-series access         |
| `collect(dim)`              | copied vector                                     | explicit copy                        |

Use `dim.vec` when you want the whole series without introducing an extra copy.
Use `collect(dim)` when you need a distinct vector for mutation or ownership boundaries.

---

## Quick reference: exported names

Types (unexported; qualify with `SomatSIE.`):

`SieFile`, `Test`, `Channel`, `Dimension`, `Tags`, `SieError`

Exported functions:

`opensie`, `readsie`, `findchannel`, `detachsie`

Navigation and identity are accessed as **dot properties** on the
returned types (`f.tests`, `f.tags`, `t.id`, `t.channels`,
`t.tags`, `ch.id`, `ch.name`, `ch.dims`, `ch.tags`, `ch.schema`, `ch.sr`,
`ch.description`, `ch.datatype`, `ch.filtfreq`, `ch.filttype`, `ch.rangemin`,
`ch.rangemax`, `ch.eunits`, `ch.erangemin`, `ch.erangemax`, `ch.time`, `ch.data`,
`dim.id`, `dim.tags`, `dim.vec`, `dim.data`, `dim.label`, `dim.units`,
`dim.description`) — there are no exported `tests` / `channels` /
`dimensions` / `tags` / `id` / `name` functions.

> Counts are obtained via `length(f.tests)`, `length(t.channels)`,
> `length(ch.dims)`, `length(x.tags)`.
>
> Channels live under tests. `f.channels` raises an error because
> channel ids may collide between tests; iterate with
> `for t in f.tests, ch in t.channels` (or build the flat list with
> `[ch for t in f.tests for ch in t.channels]`).

> Per-element positional access is via vector indexing, e.g.
> `f.tests[1]`, `f.tests[1].channels[1]`, `ch.dims[1]`.

> The `Spigot` / `Output` block-iteration types are kept internal
> (`SomatSIE.spigot`, `SomatSIE.Output`). Prefer `collect(dim)` /
> `dim[i]` / `dim[a:b]` for typical use.
