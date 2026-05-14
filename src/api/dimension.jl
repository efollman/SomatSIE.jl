# Dimension:
"""
    FileDimension{T} <: AbstractVector{T}
    const Dimension = FileDimension

A single axis ("column") of a [`Channel`](@ref). Two concrete subtypes:

* [`LibSieDimension{T}`](@ref) — backed by a libsie handle on an open
  [`SieFile`](@ref). Reads are routed through a per-channel block cache
  so random/range access only decodes the necessary blocks. Element type
  is determined by probing the channel: `Float64` for engineering-value
  columns, `Vector{UInt8}` for raw payload columns (e.g. CAN frames).
* [`Dimension{T}`](@ref) — backed by an in-memory `Vector{T}`.
  Cheap to construct from edited or synthetic data, and lets functions
  written for `Channel`/`Dimension` consume hand-built input.

Both behave as proper `AbstractVector{T}`s — `dim[i]`, `dim[a:b]`,
`collect(dim)`, iteration, and pass-through to DataFrames / Makie all
work. Identity and metadata: `dim.id` (1-based), `dim.tags`.

Construct an in-memory dimension via:

    Dimension(data::AbstractVector; id=1, tags=Tags()) -> Dimension
"""
abstract type FileDimension{T} end

"""
    LibSieDimension{T} <: FileDimension{T}

A `Dimension` backed by a libsie handle on an open [`SieFile`](@ref).
Constructed only by the library; reads are cached per-channel.
"""
struct LibSieDimension{T} <: FileDimension{T}
    handle::Ptr{Cvoid}
    parent::Any  # LibSieChannel — typed Any to avoid forward declaration
end

"""
    Dimension{T} <: FileDimension{T}

A `Dimension` whose samples live in a regular Julia `Vector{T}`. Build
one with `Dimension(data; id=1, tags=Tags())`. Mutable: `vd.id`,
`vd.tags`, and `vd.vec` may all be reassigned.
"""
mutable struct Dimension{T}
    vec::Vector{T}
    id::Int
    tags::Tags
end
Base.eltype(::Type{Dimension{T}}) where {T} = T
Base.eltype(d::Dimension{T}) where {T} = T
Base.eltype(::Type{LibSieDimension{T}}) where {T} = T
Base.eltype(d::LibSieDimension{T}) where {T} = T

# Public outer constructor — `Dimension(data; ...)` resolves through the
# `const Dimension = FileDimension` alias to this method.
function Dimension(
    data::AbstractVector;
    id::Integer = 1,
    tags::Tags = Tags(),
)
    v = data isa Vector ? data : collect(data)
    T = eltype(v)
    return Dimension{T}(v, Int(id), tags)
end

# Internal accessors — split per concrete type:
_id(d::LibSieDimension) = (
    _check_open((d.parent::LibSieChannel).parent::SieFile);
    Int(L.sie_dimension_index(d.handle)) + 1
)
_tags(d::LibSieDimension) = (
    _check_open((d.parent::LibSieChannel).parent::SieFile);
    _build_tags(d.handle, Int(L.sie_dimension_num_tags(d.handle)), L.sie_dimension_tag)
)

_id(d::Dimension) = d.id
_tags(d::Dimension) = d.tags


_dim_tag(d::Union{Dimension,LibSieDimension}, key::AbstractString, default::AbstractString="") =
    get(_tags(d), key, default)

_label(d::Union{Dimension,LibSieDimension}) = _dim_tag(d, "core:label")
_units(d::Union{Dimension,LibSieDimension}) = _dim_tag(d, "core:units")
_description(d::Union{Dimension,LibSieDimension}) = _dim_tag(d, "core:description")


function Base.getproperty(d::LibSieDimension, sym::Symbol)
    sym === :id && return _id(d)
    sym === :tags && return _tags(d)
    sym === :vec && return DimensionVecRef(d)
    sym === :data && return DimensionVecRef(d)
    sym === :label && return _label(d)
    sym === :units && return _units(d)
    sym === :description && return _description(d)
    return getfield(d, sym)
end
function Base.getproperty(d::Dimension, sym::Symbol)
    sym === :data && return getfield(d, :vec)
    sym === :label && return _label(d)
    sym === :units && return _units(d)
    sym === :description && return _description(d)
    return getfield(d, sym)
end
function Base.setproperty!(d::Dimension, sym::Symbol, v)
    sym === :data && return setfield!(d, :vec, v)
    return setfield!(d, sym, v)
end
Base.propertynames(d::Union{Dimension,LibSieDimension}, private::Bool = false) =
    private ? (fieldnames(typeof(d))..., :id, :tags, :vec, :data, :label, :units, :description) : (:id, :tags, :vec, :data, :label, :units, :description)

Base.show(io::IO, d::Union{Dimension,LibSieDimension}) =
    print(io, "Dimension(id=", _id(d), ", n=", length(d), ")")

# ── Dimension: AbstractArray interface (delegates to backing data) ──
Base.length(d::Dimension) = length(d.vec)

struct DimensionVecRef{T}
    dim::LibSieDimension{T}
end
Base.read(r::DimensionVecRef) = collect(r.dim)
Base.read(r::DimensionVecRef, i::Integer) = read(r, i:i)
function Base.read(r::DimensionVecRef, idx::AbstractUnitRange{<:Integer})
    v = collect(r.dim)
    isempty(idx) && return v[1:0]
    first(idx) >= 1 || throw(BoundsError(v, first(idx)))
    last(idx) <= length(v) || throw(BoundsError(v, last(idx)))
    return v[idx]
end

# ── LibSieDimension: cache-routed access ──
#
# `LibSieDimension <: AbstractVector{T}`, so `firstindex`, `lastindex`,
# `size`, `eltype`, `IndexStyle`, etc. come from Base. We override the
# methods below to route through the per-channel block cache instead of
# falling back to per-element scalar reads:
#
#   length(dim)         total sample count (from cache)
#   dim[i]              one sample — only the containing block is fetched
#   dim[a:b]            sub-range — only the overlapping blocks are fetched
#   dim[:] / collect    full materialized vector via the cache
#   for x in dim ...    iterates the materialized vector

# Forward declarations satisfied later in the load order:
#   ChannelCache, _channel_cache, _block_for, _locate_row, _readdim

Base.length(d::LibSieDimension) = numrows((d.parent::LibSieChannel).parent::SieFile, d.parent::LibSieChannel)
Base.collect(d::LibSieDimension) = _readdim(d)

# Iteration uses the default `AbstractArray` iterate, which calls
# `getindex` per step. Each `getindex` hits the per-channel block cache,
# so sequential traversal decodes each block once and then reuses it —
# cheap, and crucially it does NOT eagerly materialize the entire
# dimension before yielding the first element.
