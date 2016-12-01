# This file is a part of Julia. License is MIT: http://julialang.org/license

module Enums

import Core.Intrinsics.box
export AbstractEnum, Enum, @enum, EnumSet, @enumset

abstract AbstractEnum
abstract Enum <: AbstractEnum

Base.convert{T<:Integer}(::Type{T}, x::Enum) = convert(T, box(Int32, x))

Base.write(io::IO, x::Enum) = write(io, Int32(x))
Base.read{T<:Enum}(io::IO, ::Type{T}) = T(read(io, Int32))

# generate code to test whether expr is in the given set of values
function membershiptest(expr, values)
    lo, hi = extrema(values)
    if length(values) == hi - lo + 1
        :($lo <= $expr <= $hi)
    elseif length(values) < 20
        foldl((x1,x2)->:($x1 || ($expr == $x2)), :($expr == $(values[1])), values[2:end])
    else
        :($expr in $(Set(values)))
    end
end

@noinline enum_argument_error(typename, x) = throw(ArgumentError(string("invalid value for Enum $(typename): $x")))

"""
    @enum EnumName EnumValue1[=x] EnumValue2[=y]

Create an `Enum` type with name `EnumName` and enum member values of
`EnumValue1` and `EnumValue2` with optional assigned values of `x` and `y`, respectively.
`EnumName` can be used just like other types and enum member values as regular values, such as

```jldoctest
julia> @enum FRUIT apple=1 orange=2 kiwi=3

julia> f(x::FRUIT) = "I'm a FRUIT with value: \$(Int(x))"
f (generic function with 1 method)

julia> f(apple)
"I'm a FRUIT with value: 1"
```
"""
macro enum(T,syms...)
    if isempty(syms)
        throw(ArgumentError("no arguments given for Enum $T"))
    end
    if !isa(T,Symbol)
        throw(ArgumentError("invalid type expression for enum $T"))
    end
    typename = T
    vals = Array{Tuple{Symbol,Integer}}(0)
    lo = hi = 0
    i = Int32(-1)
    hasexpr = false
    for s in syms
        if isa(s,Symbol)
            if i == typemax(typeof(i))
                throw(ArgumentError("overflow in value \"$s\" of Enum $typename"))
            end
            i += one(i)
        elseif isa(s,Expr) &&
               (s.head == :(=) || s.head == :kw) &&
               length(s.args) == 2 && isa(s.args[1],Symbol)
            i = eval(current_module(),s.args[2]) # allow exprs, e.g. uint128"1"
            if !isa(i, Integer)
                throw(ArgumentError("invalid value for Enum $typename, $s=$i; values must be integers"))
            end
            i = convert(Int32, i)
            s = s.args[1]
            hasexpr = true
        else
            throw(ArgumentError(string("invalid argument for Enum ", typename, ": ", s)))
        end
        if !Base.isidentifier(s)
            throw(ArgumentError("invalid name for Enum $typename; \"$s\" is not a valid identifier."))
        end
        push!(vals, (s,i))
        if length(vals) == 1
            lo = hi = i
        else
            lo = min(lo, i)
            hi = max(hi, i)
        end
    end
    values = Int32[i[2] for i in vals]
    if hasexpr && values != unique(values)
        throw(ArgumentError("values for Enum $typename are not unique"))
    end
    blk = quote
        # enum definition
        Base.@__doc__(bitstype 32 $(esc(T)) <: Enum)
        function Base.convert(::Type{$(esc(typename))}, x::Integer)
            $(membershiptest(:x, values)) || enum_argument_error($(Expr(:quote, typename)), x)
            box($(esc(typename)), convert(Int32, x))
        end
        Base.typemin(x::Type{$(esc(typename))}) = $(esc(typename))($lo)
        Base.typemax(x::Type{$(esc(typename))}) = $(esc(typename))($hi)
        Base.isless(x::$(esc(typename)), y::$(esc(typename))) = isless(Int32(x), Int32(y))
        let insts = ntuple(i->$(esc(typename))($values[i]), $(length(vals)))
            Base.instances(::Type{$(esc(typename))}) = insts
        end
        function Base.print(io::IO, x::$(esc(typename)))
            for (sym, i) in $vals
                if i == Int32(x)
                    print(io, sym); break
                end
            end
        end
        function Base.show(io::IO, x::$(esc(typename)))
            if get(io, :compact, false)
                print(io, x)
            else
                print(io, x, "::")
                showcompact(io, typeof(x))
                print(io, " = ", Int(x))
            end
        end
        function Base.show(io::IO, t::Type{$(esc(typename))})
            Base.show_datatype(io, t)
        end
        function Base.show(io::IO, ::MIME"text/plain", t::Type{$(esc(typename))})
            print(io, "Enum ")
            Base.show_datatype(io, t)
            print(io, ":")
            for (sym, i) in $vals
                print(io, "\n", sym, " = ", i)
            end
        end
    end
    if isa(T,Symbol)
        for (sym,i) in vals
            push!(blk.args, :(const $(esc(sym)) = $(esc(T))($i)))
        end
    end
    push!(blk.args, :nothing)
    blk.head = :toplevel
    return blk
end

abstract EnumSet <: AbstractEnum

Base.convert{T<:Integer}(::Type{T}, x::EnumSet) = convert(T, convert(Unsigned, x))

for op in (:|, :&, :xor)
    @eval function Base.$op{T<:EnumSet}(x::T,y::T)
        reinterpret(T, ($op)(convert(Unsigned, x), convert(Unsigned, y)))
    end
end

Base.union{T<:EnumSet}(x::T, y::T) = x | y
Base.intersect{T<:EnumSet}(x::T, y::T) = x & y
Base.issubset{T<:EnumSet}(x::T, y::T) = x & y == x
Base.setdiff{T<:EnumSet}(x::T, y::T) = x & xor(x, y)

"""
    @enumset EnumName[::U] EnumValue1[=x] EnumValue2[=y]

Create an [`EnumSet`](:obj:`EnumSet`) type with name `EnumName` and base member values of
`EnumValue1` and `EnumValue2`, based on the unsigned integer type `U` (`UInt32` by
default).  The optional assigned values of `x` and `y` must have exactly 1 bit set, and
not overlap. `EnumName` can be used just like other types and enum member values as
regular values, such as

```jldoctest
julia> @enumset FRUITSET apple=1<<0 orange=1<<1 kiwi=1<<2

julia> f(x::FRUITSET) = "I'm a FRUITSET with value: \$(Int(x))"
f (generic function with 1 method)

julia> f(apple|kiwi)
"I'm a FRUITSET with value: 5"
```
"""
macro enumset(T,syms...)
    if isempty(syms)
        throw(ArgumentError("no arguments given for EnumSet $T"))
    end
    if isa(T,Symbol)
        typename = T
        basetype = UInt32
    elseif isa(T,Expr) && T.head == :(::) && length(T.args) == 2 && isa(T.args[1], Symbol)
        typename = T.args[1]
        basetype = eval(current_module(),T.args[2])
        if !isa(basetype, DataType) || !(basetype <: Unsigned) || !isbits(basetype)
            throw(ArgumentError("invalid base type for Enum $typename, $T=::$basetype; base type must be an unsigned integer bitstype"))
        end
    else
        throw(ArgumentError("invalid type expression for EnumSet $T"))
    end
    vals = Array{Tuple{Symbol,basetype}}(0)
    mask = zero(basetype)
    for s in syms
        if isa(s,Symbol)
            if mask & prevpow2(typemax(basetype)) != 0
                throw(ArgumentError("overflow in value \"$s\" of EnumSet $typename"))
            end
            i = max(prevpow2(mask) << 1, 1)
        elseif isa(s,Expr) &&
               (s.head == :(=) || s.head == :kw) &&
               length(s.args) == 2 && isa(s.args[1],Symbol)
            i = eval(current_module(),s.args[2]) # allow exprs, e.g. uint128"1"
            if !isa(i, Integer)
                throw(ArgumentError("invalid value for EnumSet $typename, $s=$i; values must be integers"))
            end
            i = convert(basetype, i)
            if count_ones(i) != 1
                throw(ArgumentError("invalid value for EnumSet $typename, $s=$i; value must have eactly 1 bit set"))
            elseif mask & i != 0
                throw(ArgumentError("invalid value for EnumSet $typename, $s=$i; overlap with earlier value"))
            end
            s = s.args[1]
            hasexpr = true
        else
            throw(ArgumentError(string("invalid argument for Enum ", typename, ": ", s)))
        end
        if !Base.isidentifier(s)
            throw(ArgumentError("invalid name for Enum $typename; \"$s\" is not a valid identifier."))
        end
        push!(vals, (s,i))
        mask |= i
    end
    values = basetype[i[2] for i in vals]
    blk = quote
        # enum definition
        Base.@__doc__(bitstype $(sizeof(basetype) * 8) $(esc(typename)) <: EnumSet)
        $(esc(typename))() = reinterpret($(esc(typename)), zero($basetype))
        function Base.convert(::Type{$(esc(typename))}, x::Integer)
            if 0 <= x <= $mask &&
                (xx = convert($basetype, x); xx & $mask == xx)
                return reinterpret($(esc(typename)), xx)
            else
                throw(ArgumentError(string($"invalid value for Enum $(typename): ", x)))
            end
        end
        Base.convert(::Type{$basetype}, x::$(esc(typename))) = reinterpret($basetype, x)
        Base.convert(::Type{Unsigned}, x::$(esc(typename))) = reinterpret($basetype, x)
        Base.typemin(x::Type{$(esc(typename))}) = $(esc(typename))(0)
        Base.typemax(x::Type{$(esc(typename))}) = $(esc(typename))($mask)
        Base.isless(x::$(esc(typename)), y::$(esc(typename))) = isless($basetype(x), $basetype(y))
        let insts = ntuple(i->$(esc(typename))($values[i]), $(length(vals)))
            Base.instances(::Type{$(esc(typename))}) = insts
        end
        function Base.print(io::IO, x::$(esc(typename)))
            showcompact(io, typeof(x))
            print(io, '(')
            first = true
            for (sym, i) in $vals
                if i & $basetype(x) != 0
                    if first
                        first = false
                    else
                        print(io, '|')
                    end
                    print(io, sym)
                end
            end
            print(io, ')')
        end
        function Base.show(io::IO, x::$(esc(typename)))
            print(io, x)
            if !get(io, :compact, false)
                print(io, " = ")
                show(io, $basetype(x))
            end
        end
        function Base.show(io::IO, t::Type{$(esc(typename))})
            Base.show_datatype(io, t)
        end
        function Base.show(io::IO, ::MIME"text/plain", t::Type{$(esc(typename))})
            print(io, "EnumSet ")
            Base.show_datatype(io, t)
            print(io, ":")
            for (sym, i) in $vals
                print(io, "\n", sym, " = ")
                show(io, i)
            end
        end
    end
    for (sym,i) in vals
        push!(blk.args, :(const $(esc(sym)) = $(esc(typename))($i)))
    end
    push!(blk.args, :nothing)
    blk.head = :toplevel
    return blk
end


end # module
