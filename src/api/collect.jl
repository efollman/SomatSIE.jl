# detachsie: materialize a libsie-backed Test / Channel / Dimension (or
# any nested combination) into the in-memory `Vector*` variants. The
# returned objects are detached from the underlying `SieFile` and remain
# valid after it is closed.
#
# Idempotent: passing an already-in-memory value returns it unchanged
# (no copy), so `detachsie` can be called freely in pipelines without
# worrying about double-allocation.

"""
    detachsie(d::SomatSIE.Dimension) -> Dimension
    detachsie(c::SomatSIE.Channel)   -> Channel
    detachsie(t::SomatSIE.Test)      -> Test
    detachsie(f::SomatSIE.SieFile)   -> Vector{Test}

Materialize a libsie-backed value into its in-memory `Vector*` variant.
For a `Dimension`, all samples are read through the per-channel block
cache into a typed `Vector{T}`. For a `Channel` or `Test`, every nested
dimension is collected, producing a fully detached object that remains
valid after the source [`SieFile`](@ref) is closed.

Already in-memory values (`Dimension`, `Channel`,
`Test`) are returned unchanged \u2014 the function is idempotent
and zero-copy on that path.
# When to use
Libsie-backed dimensions already read through a per-channel block cache,
so partial / random access on large files is cheap without `detachsie`.
Reach for `detachsie` (or `collect(dim)` on individual dimensions)
when you plan to do substantial work on the data — filtering, FFTs,
repeated full passes — because operating on a plain `Vector` skips
the per-call cache lookup and bounds checks. It is also the right tool
when you need values to remain valid after the source `SieFile` is
closed.
```julia
opensie(\"file.sie\") do f
    snapshot = detachsie(f)        # Vector{Test}, detached
end
# `snapshot` still works here, even though `f` is closed.
```
"""
function detachsie end

# Dimension:
detachsie(d::Dimension) = d
detachsie(d::LibSieDimension) = Dimension{eltype(d)}(collect(d), _id(d), _tags(d))

# Channel:
detachsie(c::Channel) = c
function detachsie(c::LibSieChannel)
    dims = Union{Dimension,LibSieDimension}[detachsie(d) for d in _dimensions(c)]
    return Channel(_name(c), dims; id = _id(c), tags = _tags(c))
end

# Test:
detachsie(t::Test) = t
function detachsie(t::LibSieTest)
    chs = Union{Channel,LibSieChannel}[detachsie(c) for c in _channels(t)]
    return Test(chs; id = _id(t), tags = _tags(t))
end

# SieFile: collect every test. Returns a plain `Vector{Test}`
# rather than a synthetic `SieFile` (we have no in-memory `SieFile`
# subtype, and a SIE file is not a meaningful concept once detached).
detachsie(sf::SieFile) = Test[detachsie(t) for t in _tests(sf)]
