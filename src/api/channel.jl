# Channel:
"""
    Union{Channel,LibSieChannel}
    const Channel = Union{Channel,LibSieChannel}

A data series within a [`SieFile`](@ref). Two concrete subtypes:

* [`LibSieChannel`](@ref) — backed by a libsie handle on an open
  [`SieFile`](@ref). All metadata and dimension data come from the file.
* [`Channel`](@ref) — backed by hand-built dimensions
  ([`Dimension`](@ref) or any other `FileDimension`). Lets you
  pass synthetic / edited data to functions written against `Channel`.

Access via dot syntax on either subtype: `ch.id`, `ch.name`, `ch.dims`,
`ch.tags`, plus the convenience accessors `ch.schema` (the `core:schema`
tag, or `nothing`) and `ch.sr` (the `core:sample_rate` tag parsed as
`Float64`, or `NaN` if unset/unparseable).

Construct an in-memory channel via:

    Channel(name::AbstractString, dims::AbstractVector{<:FileDimension};
            id=1, tags=Tags()) -> Channel
"""
abstract type FileChannel end

"""
    LibSieChannel <: Union{Channel,LibSieChannel}

A `Channel` backed by a libsie handle on an open [`SieFile`](@ref).
Constructed only by the library.
"""
struct LibSieChannel <: FileChannel
    handle::Ptr{Cvoid}
    parent::Any   # keeps SieFile alive
end

"""
    Channel <: Union{Channel,LibSieChannel}

A `Channel` whose dimensions are held in a regular Julia vector. Build
one with `Channel(name, dims; id=1, tags=Tags())`. Mutable: `vc.name`,
`vc.id`, `vc.tags`, and `vc.dims` may all be reassigned.
"""
mutable struct Channel
    name::String
    id::Int
    tags::Tags
    dims::Vector{Dimension}
end

# Public outer constructor — `Channel(name, dims; ...)` resolves through
# the `const Channel = Union{Channel,LibSieChannel}` alias to this method.
function Channel(
    name::AbstractString,
    dims::AbstractVector;
    id::Integer = 1,
    tags::Tags = Tags(),
)
    ds = Vector{Dimension}(undef, length(dims))
    @inbounds for (i, d) in enumerate(dims)
        d isa Dimension || throw(
            ArgumentError("Channel dims must be `Dimension`s; got $(typeof(d))"),
        )
        ds[i] = d
    end
    return Channel(String(name), Int(id), tags, ds)
end

_id(c::LibSieChannel) =
    (_check_open(c.parent::SieFile); Int(L.sie_channel_id(c.handle)) + 1)
_name(c::LibSieChannel) =
    (_check_open(c.parent::SieFile); _ptrlen_to_string(L.sie_channel_name, c.handle))
_numdims(c::LibSieChannel) =
    (_check_open(c.parent::SieFile); Int(L.sie_channel_num_dims(c.handle)))
_tags(c::LibSieChannel) = (
    _check_open(c.parent::SieFile);
    _build_tags(c.handle, Int(L.sie_channel_num_tags(c.handle)), L.sie_channel_tag)
)

_id(c::Channel) = c.id
_name(c::Channel) = c.name
_numdims(c::Channel) = length(c.dims)
_tags(c::Channel) = c.tags

# `core:schema` tag, or `nothing` if absent. Polymorphic over both subtypes.
_schema(c::Union{Channel,LibSieChannel}) = get(_tags(c), "core:schema", nothing)

# `core:sample_rate` tag parsed as Float64; NaN if absent/unparseable.
function _sample_rate(c::Union{Channel,LibSieChannel})
    v = get(_tags(c), "core:sample_rate", nothing)
    v === nothing && return NaN
    s = v isa AbstractString ? v : String(copy(v))
    return something(tryparse(Float64, s), NaN)
end

_ch_tag(c::Union{Channel,LibSieChannel}, key::AbstractString, default::AbstractString="") =
    get(_tags(c), key, default)

_ch_tag_float(c::Union{Channel,LibSieChannel}, key::AbstractString) = begin
    v = get(_tags(c), key, nothing)
    v === nothing && return NaN
    sv = v isa AbstractString ? v : String(copy(v))
    return something(tryparse(Float64, sv), NaN)
end

_description(c::Union{Channel,LibSieChannel}) = _ch_tag(c, "core:description")
_datatype(c::Union{Channel,LibSieChannel}) = _ch_tag(c, "data_type")
_filtfreq(c::Union{Channel,LibSieChannel}) = _ch_tag_float(c, "somat:digital_filter_attenuation_frequency")
_filttype(c::Union{Channel,LibSieChannel}) = _ch_tag(c, "somat:digital_filter_type")
_rangemin(c::Union{Channel,LibSieChannel}) = _ch_tag_float(c, "somat:physical_range_min")
_rangemax(c::Union{Channel,LibSieChannel}) = _ch_tag_float(c, "somat:physical_range_max")
_eunits(c::Union{Channel,LibSieChannel}) = _ch_tag(c, "somat:electrical_units")
_erangemin(c::Union{Channel,LibSieChannel}) = _ch_tag_float(c, "somat:electrical_range_min")
_erangemax(c::Union{Channel,LibSieChannel}) = _ch_tag_float(c, "somat:electrical_range_max")

function _is_timeseries_schema(c::Union{Channel,LibSieChannel})
    schema = _schema(c)
    schema == "timhis" && return true
    if schema == "somat:sequential"
        return get(_tags(c), "somat:datamode_type", nothing) == "time_history"
    end
    return false
end
_time(c::Union{Channel,LibSieChannel}) =
    (_is_timeseries_schema(c) && length(_dimensions(c)) >= 1) ? _dimensions(c)[1] : Float64[]
_data(c::Union{Channel,LibSieChannel}) =
    (_is_timeseries_schema(c) && length(_dimensions(c)) >= 2) ? _dimensions(c)[2] : Float64[]

function _dimension(c::LibSieChannel, i::Integer)
    _check_open(c.parent::SieFile)
    1 <= i <= _numdims(c) || throw(BoundsError(c, i))
    h = L.sie_channel_dimension(c.handle, i - 1)
    h == C_NULL && throw(BoundsError(c, i))
    T = _probe_dim_eltypes(c, _numdims(c))[i]
    return LibSieDimension{T}(h, c)
end

function _dimensions(c::LibSieChannel)
    _check_open(c.parent::SieFile)
    n = _numdims(c)
    types = _probe_dim_eltypes(c, n)
    out = Vector{LibSieDimension}(undef, n)
    @inbounds for i = 1:n
        h = L.sie_channel_dimension(c.handle, i - 1)
        h == C_NULL && throw(BoundsError(c, i))
        out[i] = LibSieDimension{types[i]}(h, c)
    end
    return sort(out; by = _id)
end

_dimension(c::Channel, i::Integer) =
    (1 <= i <= length(c.dims) || throw(BoundsError(c, i)); c.dims[i])
_dimensions(c::Channel) = c.dims

# Probe the element types of all dimensions of a channel by attaching a
# transient spigot, reading the type tag of the first block, and freeing.
# Empty channels (no blocks at all) fall back to `Float64` so that
# downstream `Vector{Float64}` allocations remain well-defined. Real
# libsie failures (attach/get errors) propagate as `SieError` rather
# than being silently masked.
function _probe_dim_eltypes(c::LibSieChannel, n::Int)
    file = c.parent::SieFile
    types = fill(Float64, n)::Vector{DataType}
    spig_ref = Ref{Ptr{Cvoid}}(C_NULL)
    _check(L.sie_spigot_attach(_check_open(file), c.handle, spig_ref))
    sp = spig_ref[]
    try
        out_ref = Ref{Ptr{Cvoid}}(C_NULL)
        rc = L.sie_spigot_get(sp, out_ref)
        # Stream-ended on a channel with no blocks: leave the Float64
        # default in place (the dimensions are empty, so the eltype is
        # immaterial to correctness).
        rc == L.SIE_E_STREAM_ENDED && return types
        _check(rc)
        outh = out_ref[]
        outh == C_NULL && return types  # also treat NULL as end-of-stream
        @inbounds for i = 1:n
            t = L.sie_output_type(outh, Csize_t(i - 1))
            types[i] =
                t == L.SIE_OUTPUT_FLOAT64 ? Float64 :
                t == L.SIE_OUTPUT_RAW ? Vector{UInt8} : Float64
        end
    finally
        L.sie_spigot_free(sp)
    end
    return types
end

function Base.getproperty(c::LibSieChannel, sym::Symbol)
    sym === :id && return _id(c)
    sym === :name && return _name(c)
    sym === :dims && return _dimensions(c)
    sym === :tags && return _tags(c)
    sym === :schema && return _schema(c)
    sym === :sr && return _sample_rate(c)
    sym === :description && return _description(c)
    sym === :datatype && return _datatype(c)
    sym === :filtfreq && return _filtfreq(c)
    sym === :filttype && return _filttype(c)
    sym === :rangemin && return _rangemin(c)
    sym === :rangemax && return _rangemax(c)
    sym === :eunits && return _eunits(c)
    sym === :erangemin && return _erangemin(c)
    sym === :erangemax && return _erangemax(c)
    sym === :time && return _time(c)
    sym === :data && return _data(c)
    return getfield(c, sym)
end
function Base.getproperty(c::Channel, sym::Symbol)
    sym === :schema && return _schema(c)
    sym === :sr && return _sample_rate(c)
    sym === :description && return _description(c)
    sym === :datatype && return _datatype(c)
    sym === :filtfreq && return _filtfreq(c)
    sym === :filttype && return _filttype(c)
    sym === :rangemin && return _rangemin(c)
    sym === :rangemax && return _rangemax(c)
    sym === :eunits && return _eunits(c)
    sym === :erangemin && return _erangemin(c)
    sym === :erangemax && return _erangemax(c)
    sym === :time && return _time(c)
    sym === :data && return _data(c)
    return getfield(c, sym)   # id, name, dims, tags are real fields
end
Base.propertynames(::Union{Channel,LibSieChannel}, private::Bool = false) =
    (:id, :name, :dims, :tags, :schema, :sr, :description, :datatype, :filtfreq, :filttype, :rangemin, :rangemax, :eunits, :erangemin, :erangemax, :time, :data)

Base.show(io::IO, c::Union{Channel,LibSieChannel}) = print(
    io,
    "Channel(id=",
    _id(c),
    ", name=",
    repr(_name(c)),
    ", ndims=",
    _numdims(c),
    ")",
)

"""
    length(ch::SomatSIE.Channel) -> Int

Number of samples per dimension. For a [`LibSieChannel`](@ref) this
consults the per-channel block cache (one `ccall` per block on first
access, free thereafter). For a [`Channel`](@ref) this is
`length(first(ch.dims))` — 0 if the channel has no dimensions.

Assumes every dimension of `ch` has the same length, which is the
invariant libsie maintains for SIE channels and which `Channel(...)`
construction does not enforce — mixed-length `Channel`s will
report the length of dim 1 only.
"""
Base.length(c::LibSieChannel) = numrows(c.parent::SieFile, c)
Base.length(c::Channel) = isempty(c.dims) ? 0 : length(@inbounds c.dims[1])


Base.sort(v::AbstractVector{<:Union{Channel,LibSieChannel}}; by = _id, kws...) =
    invoke(Base.sort, Tuple{AbstractVector}, v; by = by, kws...)
Base.sort!(v::AbstractVector{<:Union{Channel,LibSieChannel}}; by = _id, kws...) =
    invoke(Base.sort!, Tuple{AbstractVector}, v; by = by, kws...)
