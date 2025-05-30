using Test
using JET
import Dates
import Random: seed!
import Base.Broadcast: materialize, materialize!
import LazyBroadcast: @lazy
import BenchmarkTools as BT

import ClimaComms
import BenchmarkTools as BT
ClimaComms.@import_required_backends
import ClimaCore:
    Utilities,
    Geometry,
    Domains,
    Meshes,
    Topologies,
    Hypsography,
    Spaces,
    Fields,
    Operators,
    Quadratures
using ClimaCore.MatrixFields

# Test that an expression is true and that it is also type-stable.
macro test_all(expression)
    return quote
        local test_func() = $(esc(expression))
        @test test_func()                   # correctness
        @test (@allocated test_func()) == 0 # allocations
        @test_opt test_func()               # type instabilities
    end
end

# Compute the minimum time (in seconds) required to run an expression after it 
# has been compiled. This macro is used instead of @benchmark from
# BenchmarkTools.jl because the latter is extremely slow (it appears to keep
# triggering recompilations and allocating a lot of memory in the process).
macro benchmark(expression)
    return quote
        $(esc(expression)) # Compile the expression first. Use esc for hygiene.
        best_time = Inf
        start_time = time_ns()
        while time_ns() - start_time < 1e8 # Benchmark for 0.1 s (1e8 ns).
            best_time = min(best_time, @elapsed $(esc(expression)))
        end
        best_time
    end
end

const comms_device = ClimaComms.device()
# comms_device = ClimaComms.CPUSingleThreaded()
@show comms_device
const using_cuda = comms_device isa ClimaComms.CUDADevice
cuda_module(ext) = using_cuda ? ext.CUDA : ext
const cuda_mod = cuda_module(Base.get_extension(ClimaComms, :ClimaCommsCUDAExt))
const cuda_frames = using_cuda ? (AnyFrameModule(cuda_mod),) : ()
const cublas_frames = using_cuda ? (AnyFrameModule(cuda_mod.CUBLAS),) : ()
const invalid_ir_error = using_cuda ? cuda_mod.InvalidIRError : ErrorException

# Test the allocating and non-allocating versions of a field broadcast against
# a reference non-allocating implementation. Ensure that they are performant,
# correct, and type-stable, and print some useful information. If a reference
# implementation is not available, the performance and correctness checks are
# skipped.
function test_field_broadcast(;
    test_name,
    get_result,
    set_result,
    ref_set_result = nothing,
    time_ratio_limit = 10,
    max_eps_error_limit = 10,
    test_broken_with_cuda = false,
)
    @testset "$test_name" begin
        if test_broken_with_cuda && using_cuda
            @test_throws invalid_ir_error materialize(get_result)
            @warn "$test_name:\n\tCUDA.InvalidIRError"
            return
        end

        result = materialize(get_result)
        result_copy = copy(result)
        time = @benchmark materialize!(result, set_result)
        time_rounded = round(time; sigdigits = 2)

        # Test that set_result! sets the same value as get_result.
        @test result == result_copy

        if isnothing(ref_set_result)
            @info "$test_name:\n\tTime = $time_rounded s (reference \
                   implementation unavailable)"
        else
            ref_result = similar(result)
            ref_time = @benchmark materialize!(ref_result, ref_set_result)
            ref_time_rounded = round(ref_time; sigdigits = 2)
            time_ratio = time / ref_time
            time_ratio_rounded = round(time_ratio; sigdigits = 2)
            max_error = mapreduce(
                (a, b) -> (abs(a - b)),
                max,
                parent(result),
                parent(ref_result),
            )
            max_eps_error = ceil(Int, max_error / eps(typeof(max_error)))

            @info "$test_name:\n\tTime Ratio = $time_ratio_rounded \
                   ($time_rounded s vs. $ref_time_rounded s for reference) \
                   \n\tMaximum Error = $max_eps_error eps"

            # Test that set_result! is performant and correct when compared
            # against ref_set_result.
            @test time / ref_time <= time_ratio_limit
            @test max_eps_error <= max_eps_error_limit
        end

        # Test get_result and set_result! for type instabilities, and test
        # set_result! for allocations. Ignore the type instabilities in CUDA and
        # the allocations they incur.
        @test_opt ignored_modules = cuda_frames materialize(get_result)
        @test_opt ignored_modules = cuda_frames materialize!(result, set_result)
        using_cuda || @test (@allocated materialize!(result, set_result)) == 0

        if !isnothing(ref_set_result)
            # Test ref_set_result! for type instabilities and allocations to
            # ensure that the performance comparison is fair.
            @test_opt ignored_modules = cuda_frames materialize!(
                ref_result,
                ref_set_result,
            )
            using_cuda ||
                @test (@allocated materialize!(ref_result, ref_set_result)) == 0
        end
    end
end

# Generate extruded finite difference spaces for testing. Include topography
# when possible.
function test_spaces(::Type{FT}) where {FT}
    velem = 20 # This should be big enough to test high-bandwidth matrices.
    helem = npoly = 1 # These should be small enough for the tests to be fast.

    comms_ctx = ClimaComms.SingletonCommsContext(comms_device)
    hdomain = Domains.SphereDomain(FT(10))
    hmesh = Meshes.EquiangularCubedSphere(hdomain, helem)
    htopology = Topologies.Topology2D(comms_ctx, hmesh)
    quad = Quadratures.GLL{npoly + 1}()
    hspace = Spaces.SpectralElementSpace2D(htopology, quad)
    vdomain = Domains.IntervalDomain(
        Geometry.ZPoint(FT(0)),
        Geometry.ZPoint(FT(10));
        boundary_names = (:bottom, :top),
    )
    vmesh = Meshes.IntervalMesh(vdomain, nelems = velem)
    vtopology = Topologies.IntervalTopology(comms_ctx, vmesh)
    vspace = Spaces.CenterFiniteDifferenceSpace(vtopology)
    sfc_coord = Fields.coordinate_field(hspace)
    hypsography =
        using_cuda ? Hypsography.Flat() :
        Hypsography.LinearAdaption(
            Geometry.ZPoint.(@. cosd(sfc_coord.lat) + cosd(sfc_coord.long) + 1),
        ) # TODO: FD operators don't currently work with hypsography on GPUs.
    center_space =
        Spaces.ExtrudedFiniteDifferenceSpace(hspace, vspace, hypsography)
    face_space = Spaces.FaceExtrudedFiniteDifferenceSpace(center_space)

    return center_space, face_space
end

# Generate a random field with elements of type T.
function random_field(::Type{T}, space) where {T}
    FT = Spaces.undertype(space)
    field = Fields.Field(T, space)
    parent(field) .= rand.(FT)
    return field
end

# Construct a highly nested type for testing integration with RecursiveApply.
nested_type(value) = nested_type(value, value, value)
nested_type(value1, value2, value3) =
    (; a = (), b = value1, c = (value2, (; d = (value3,)), (;)))

# A shorthand for typeof(nested_type(::FT)).
const NestedType{FT} = NamedTuple{
    (:a, :b, :c),
    Tuple{
        Tuple{},
        FT,
        Tuple{FT, NamedTuple{(:d,), Tuple{Tuple{FT}}}, NamedTuple{(), Tuple{}}},
    },
}

function call_ref_set_result!(
    ref_set_result!::F,
    ref_result_arrays,
    inputs_arrays,
    temp_values_arrays,
) where {F}
    for arrays in
        zip(ref_result_arrays, inputs_arrays..., temp_values_arrays...)
        ref_set_result!(arrays...)
    end
    return nothing
end

function print_time_comparison(; time, ref_time)
    time_rounded = round(time; sigdigits = 2)
    ref_time_rounded = round(ref_time; sigdigits = 2)
    time_ratio = time / ref_time
    time_ratio_rounded = round(time_ratio; sigdigits = 2)
    @info "Times (ClimaCore,Array,ClimaCore/Array): = ($time_rounded, $ref_time_rounded, $time_ratio_rounded)."
    return nothing
end

function compute_max_error(result_arrays, ref_result_arrays)
    return mapreduce(max, result_arrays, ref_result_arrays) do array, ref_array
        mapreduce((a, b) -> (abs(a - b)), max, array, ref_array)
    end
end

set_result!(result, bc) = (materialize!(result, bc); nothing)

function call_getidx(space, bc, idx, hidx)
    @inbounds Operators.getidx(space, bc, idx, hidx)
    return nothing
end

time_and_units_str(x::Real) =
    trunc_time(string(compound_period(x, Dates.Second)))

"""
    compound_period(x::Real, ::Type{T}) where {T <: Dates.Period}

A canonicalized `Dates.CompoundPeriod` given a real value
`x`, and its units via the period type `T`.
"""
function compound_period(x::Real, ::Type{T}) where {T <: Dates.Period}
    nf = Dates.value(convert(Dates.Nanosecond, T(1)))
    ns = Dates.Nanosecond(ceil(x * nf))
    return Dates.canonicalize(Dates.CompoundPeriod(ns))
end

trunc_time(s::String) = count(',', s) > 1 ? join(split(s, ",")[1:2], ",") : s

function get_getidx_args(bc)
    space = axes(bc)
    # TODO: change this to idx_l, idx_i, idx_r
    # may need to define a helper
    (li, lw, rw, ri) = Operators.window_bounds(space, bc)
    idx_l, idx_r = if Topologies.isperiodic(space)
        li, ri
    else
        lw, rw
    end
    idx_i = if space.staggering isa Spaces.CellCenter
        Int(round((idx_l + idx_r) / 2; digits = 0))
    else
        Utilities.PlusHalf(Int(round((idx_l + idx_r) / 2; digits = 0)))
    end
    hidx = (1, 1, 1)
    return (; space, bc, idx_l, idx_i, idx_r, hidx)
end

import JET
function perf_getidx(bc; broken = false)
    (; space, bc, idx_l, idx_i, idx_r, hidx) = get_getidx_args(bc)
    call_getidx(space, bc, idx_l, hidx)
    call_getidx(space, bc, idx_i, hidx)
    call_getidx(space, bc, idx_r, hidx)

    bel =
        time_and_units_str(BT.@belapsed call_getidx($space, $bc, $idx_l, $hidx))
    bei =
        time_and_units_str(BT.@belapsed call_getidx($space, $bc, $idx_i, $hidx))
    ber =
        time_and_units_str(BT.@belapsed call_getidx($space, $bc, $idx_r, $hidx))
    JET.@test_opt call_getidx(space, bc, idx_l, hidx)
    JET.@test_opt call_getidx(space, bc, idx_i, hidx)
    JET.@test_opt call_getidx(space, bc, idx_r, hidx)
    @info "getidx times max(left,interior,right) = ($bel,$bei,$ber)"
    return nothing
end
