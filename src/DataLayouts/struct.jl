# 1) given a Vector{T}, T<:Number, construct an object of type S using the same underlying data
# e.g.
#  array = [1.0,2.0,3.0], S = Tuple{Complex{Float64},Float64} => (1.0 + 2.0im, 3.0)

# 2) for an Array{T,N}, and some 1 <= D <= N,
#   reconstruct S from a slice of array#

# The main difference between StructArrays and what we want is that we want 1 underlying (rather than # fields)
# there is no heterogeneity in the struct (can store recursive representations) of field types

# get_offset(array, S, offset) => S(...), next_offset

"""
    basetype(S...)

Compute the "base" floating point type of one or more types `S`. This will throw
an error if there is no unique type.
"""
basetype(::Type{FT}) where {FT <: AbstractFloat} = FT
basetype(::Type{NamedTuple{names, T}}) where {names, T} = basetype(T)
function basetype(::Type{S}) where {S}
    isprimitivetype(S) && error("$S is not a floating point type")
    basetype(ntuple(i -> fieldtype(S, i), fieldcount(S))...)
end
function basetype(::Type{S1}, Sx...) where {S1}
    if sizeof(S1) == 0
        return basetype(Sx...)
    end
    FT1 = basetype(S1)
    FT2 = basetype(Sx...)
    FT1 !== FT2 && error("Inconsistent basetypes $FT1 and $FT2")
    return FT1
end

replace_basetype(::Type{S}, ::Type{FT}) where {S <: AbstractFloat, FT} = FT
function replace_basetype(::Type{S}, ::Type{FT}) where {S <: Tuple, FT}
    Tuple{ntuple(i -> replace_basetype(fieldtype(S, i), FT), fieldcount(S))...}
end
function replace_basetype(
    ::Type{NamedTuple{names, T}},
    ::Type{FT},
) where {names, T, FT}
    NamedTuple{names, replace_basetype(T, FT)}
end

"""
    parent_array_type(::Type{<:AbstractArray})

Returns the parent array type underlying the `SubArray` wrapper type
"""
parent_array_type(::Type{A}) where {A <: AbstractArray{FT}} where {FT} =
    Array{FT}
# TODO: extract interface to overload for backends into separate file

"""
    StructArrays.bypass_constructor(T, args)

Create an instance of type `T` from a tuple of field values `args`, bypassing
possible internal constructors. `T` should be a concrete type.
"""
@generated function bypass_constructor(::Type{T}, args) where {T}
    vars = ntuple(_ -> gensym(), fieldcount(T))
    assign = [
        :($var::$(fieldtype(T, i)) = getfield(args, $i)) for
        (i, var) in enumerate(vars)
    ]
    construct = Expr(:new, :T, vars...)
    Expr(:block, assign..., construct)
end

"""
    fieldtypeoffset(T,S,i)

Similar to `fieldoffset(S,i)`, but gives result in multiples of `sizeof(T)` instead of bytes.
"""
fieldtypeoffset(::Type{T}, ::Type{S}, i) where {T, S} =
    Int(div(fieldoffset(S, i), sizeof(T)))

@noinline function error_not_isbits(T::Type)
    error("$T is not isbitstype")
end

"""
    typesize(T,S)

Similar to `sizeof(S)`, but gives the result in multiples of `sizeof(T)`.
"""
function typesize(::Type{T}, ::Type{S}) where {T, S}
    isbitstype(T) || error_not_isbits(T)
    isbitstype(S) || error_not_isbits(S)
    div(sizeof(S), sizeof(T))
end

# TODO: this assumes that the field struct zero type is the same as the backing
# zero'd out memory, which should be true in all "real world" cases
# but is something that should be revisited
@inline function _mzero!(out::MArray{S, T, N, L}, FT) where {S, T, N, L}
    TdivFT = DataLayouts.typesize(FT, T)
    Base.GC.@preserve out begin
        @inbounds for i in 1:(L * TdivFT)
            Base.unsafe_store!(
                Base.unsafe_convert(Ptr{FT}, Base.pointer_from_objref(out)),
                zero(FT),
                i,
            )
        end
    end
    return out
end

"""
    get_struct(array, S[, offset=0])

Construct an object of type `S` from the values of `array`, optionally offset by `offset` from the start of the array.
"""
function get_struct(array::AbstractArray{T}, ::Type{S}, offset) where {T, S}
    if @generated
        tup = :(())
        for i in 1:fieldcount(S)
            push!(
                tup.args,
                :(get_struct(
                    array,
                    fieldtype(S, $i),
                    offset + fieldtypeoffset(T, S, $i),
                )),
            )
        end
        return quote
            Base.@_propagate_inbounds_meta
            bypass_constructor(S, $tup)
        end
    else
        args = ntuple(fieldcount(S)) do i
            get_struct(array, fieldtype(S, i), offset + fieldtypeoffset(T, S, i))
        end
        return bypass_constructor(S, args)
    end
end

# recursion base case: hit array type is the same as the struct leaf type
@propagate_inbounds function get_struct(
    array::AbstractArray{S},
    ::Type{S},
    offset,
) where {S}
    return array[offset + 1]
end

@inline function get_struct(array::AbstractArray{T}, ::Type{S}) where {T, S}
    @inbounds get_struct(array, S, 0)
end

function set_struct!(array::AbstractArray{T}, val::S, offset) where {T, S}
    if @generated
        errorstring = "Expected type $T, got type $S"
        ex = quote
            Base.@_propagate_inbounds_meta
            # TODO: need to figure out a better way to handle the case where we require conversion
            # e.g. if T = Dual or Double64
            if isprimitivetype(S)
                # error if we dont hit triangular dispatch method (defined below):
                # set_struct!(::AbstractArray{S}, ::S) where {S}
                error($errorstring)
            end
        end
        for i in 1:fieldcount(S)
            push!(
                ex.args,
                :(set_struct!(
                    array,
                    getfield(val, $i),
                    offset + fieldtypeoffset(T, S, $i),
                )),
            )
        end
        push!(ex.args, :(return nothing))
        return ex
    else
        Base.@_propagate_inbounds_meta
        if isprimitivetype(S)
            return error("Expected type $T, got type $S")
        end
        for i in 1:fieldcount(S)
            set_struct!(
                array,
                getfield(val, i),
                offset + fieldtypeoffset(T, S, i),
            )
        end
        return nothing
    end
end

@propagate_inbounds function set_struct!(
    array::AbstractArray{S},
    val::S,
    offset,
) where {S}
    array[offset + 1] = val
end

@inline function set_struct!(array, val)
    @inbounds set_struct!(array, val, 0)
end

if VERSION >= v"1.7.0-beta1"
    # For complex nested types (ex. wrapped SMatrix) we hit a recursion limit and de-optimize
    # We know the recursion will terminate due to the fact that bitstype fields
    # cannot be self referential so there are no cycles in get/set_struct (bounded tree)
    # TODO: enforce inference termination some other way
    if hasfield(Method, :recursion_relation)
        dont_limit = (args...) -> true
        for m in methods(get_struct)
            m.recursion_relation = dont_limit
        end
        for m in methods(set_struct!)
            m.recursion_relation = dont_limit
        end
    end
end
