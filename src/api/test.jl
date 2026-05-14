# Test:
"""
    Union{Test,LibSieTest}
    const Test = Union{Test,LibSieTest}

A test (acquisition session). Two concrete subtypes:

* [`LibSieTest`](@ref) \u2014 backed by a libsie handle on an open
  [`SieFile`](@ref).
* [`Test`](@ref) \u2014 backed by a vector of in-memory channels.
  Lets you pass synthetic / edited tests to functions written against
  `Test`.

Access via dot syntax on either subtype: `t.id`, `t.channels`, `t.tags`.

Construct an in-memory test via:

    SomatSIE.Test(channels::AbstractVector{<:FileChannel};
                  id=1, tags=Tags()) -> Test

`Test` is unexported; access it as `SomatSIE.Test` to avoid clashing
with `Test.Test` from the standard library.
"""
abstract type FileTest end

"""
    LibSieTest <: Union{Test,LibSieTest}

A `Test` backed by a libsie handle on an open [`SieFile`](@ref).
Constructed only by the library.
"""
struct LibSieTest <: FileTest
    handle::Ptr{Cvoid}
    parent::Any   # keeps SieFile alive
end

"""
    Test <: Union{Test,LibSieTest}

A `Test` whose channels are held in a regular Julia vector. Build one
with `SomatSIE.Test(channels; id=1, tags=Tags())`. Mutable: `vt.id`,
`vt.tags`, and `vt.channels` may all be reassigned.
"""
mutable struct Test
    id::Int
    tags::Tags
    channels::Vector{Union{Channel,LibSieChannel}}
end

# Public outer constructor \u2014 `SomatSIE.Test(channels; ...)` resolves
# through the `const Test = Union{Test,LibSieTest}` alias to this method.
function Test(
    channels::AbstractVector;
    id::Integer = 1,
    tags::Tags = Tags(),
)
    cs = Vector{Union{Channel,LibSieChannel}}(undef, length(channels))
    @inbounds for (i, c) in enumerate(channels)
        c isa Union{Channel,LibSieChannel} || throw(
            ArgumentError("Test channels must be `FileChannel`s; got $(typeof(c))"),
        )
        cs[i] = c
    end
    return Test(Int(id), tags, cs)
end

_id(t::LibSieTest) = (_check_open(t.parent::SieFile); Int(L.sie_test_id(t.handle)) + 1)
_nchannels(t::LibSieTest) =
    (_check_open(t.parent::SieFile); Int(L.sie_test_num_channels(t.handle)))
_tags(t::LibSieTest) = (
    _check_open(t.parent::SieFile);
    _build_tags(t.handle, Int(L.sie_test_num_tags(t.handle)), L.sie_test_tag)
)

_id(t::Test) = t.id
_nchannels(t::Test) = length(t.channels)
_tags(t::Test) = t.tags

function _channel(t::LibSieTest, i::Integer)
    _check_open(t.parent::SieFile)
    1 <= i <= _nchannels(t) || throw(BoundsError(t, i))
    h = L.sie_test_channel(t.handle, i - 1)
    h == C_NULL ? throw(BoundsError(t, i)) : LibSieChannel(h, t.parent)
end

_channels(t::LibSieTest) = [_channel(t, i) for i = 1:_nchannels(t)]

_channel(t::Test, i::Integer) =
    (1 <= i <= length(t.channels) || throw(BoundsError(t, i)); t.channels[i])
_channels(t::Test) = t.channels

function Base.getproperty(t::LibSieTest, sym::Symbol)
    sym === :id && return _id(t)
    sym === :channels && return _channels(t)
    sym === :tags && return _tags(t)
    return getfield(t, sym)
end
function Base.getproperty(t::Test, sym::Symbol)
    return getfield(t, sym)   # id, channels, tags are real fields
end
Base.propertynames(::Union{Test,LibSieTest}, private::Bool = false) = (:id, :channels, :tags)

Base.show(io::IO, t::Union{Test,LibSieTest}) =
    print(io, "Test(id=", _id(t), ", nchannels=", _nchannels(t), ")")
