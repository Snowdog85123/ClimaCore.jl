#=
julia --project
using Revise; include(joinpath("test", "MatrixFields", "matrix_fields_broadcasting", "test_scalar_1.jl"))
=#
import ClimaCore
#! format: off
if !(@isdefined(unit_test_field_broadcast_vs_array_reference))
    include(joinpath(pkgdir(ClimaCore),"test","MatrixFields","matrix_fields_broadcasting","test_scalar_utils.jl"))
end
#! format: on
test_opt = get(ENV, "BUILDKITE", "") == "true"
@testset "diagonal matrix times vector" begin
    bc = @lazy @. ᶜᶜmat ⋅ ᶜvec
    result = materialize(bc)

    input_fields = (ᶜᶜmat, ᶜvec)
    unit_test_field_broadcast_vs_array_reference(
        result,
        bc;
        input_fields,
        using_cuda,
    )
    test_opt && opt_test_field_broadcast_against_array_reference(
        result,
        bc;
        input_fields,
        using_cuda,
    )
end
