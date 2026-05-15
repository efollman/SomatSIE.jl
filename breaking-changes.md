# Breaking API changes in `0.4` vs `master`

Compared against `upstream/master` (`344ce2c`) and current `0.4` work (`29fbd0e`), these are the user-visible breaking API changes.

## 1) `sieDetach` was renamed to `detachsie`

If your code called `sieDetach(...)`, it must now call `detachsie(...)`.

```julia
# old
snapshot = sieDetach(f)

# new
snapshot = detachsie(f)
```

## 2) `Channel.sr` changed missing/error behavior

`ch.sr` used to return `nothing` when `core:sample_rate` was missing or unparseable.
In `0.4`, it returns `NaN` in those cases (and parses as `Float64`).

This is breaking for code that checked `isnothing(ch.sr)`.

```julia
# old
if isnothing(ch.sr)
    # ...
end

# new
if isnan(ch.sr)
    # ...
end
```

## 3) Constructor/type hierarchy changes for in-memory channels

The in-memory channel concrete type named `VectorChannel` was replaced by a concrete type named `Channel`, and constructor signatures were tightened around `Dimension`/`FileDimension`.

This is breaking for code that:
- explicitly referenced `VectorChannel`, or
- dispatched on the old abstract/concrete channel hierarchy, or
- passed non-`Dimension` values where `Channel(...)` now expects `Dimension`/`FileDimension`.

## 4) Internal cache module removed

`src/api/cache.jl` was removed and channel length now routes via `numrows(...)` instead of the prior cache accessor path.

This is breaking only for consumers that depended on non-public internals.

## 5) Additional exported function: `readsie`

`readsie` is now exported. This is usually non-breaking, but can be breaking if your environment already had a conflicting `readsie` binding brought into scope.

---

## Migration checklist

- Replace all `sieDetach(` calls with `detachsie(`.
- Update `ch.sr` handling from `nothing`-checks to `NaN`-checks.
- Remove references to `VectorChannel` and old channel hierarchy names in custom dispatch code.
- Avoid relying on non-public internals (especially anything formerly in `api/cache.jl`).
