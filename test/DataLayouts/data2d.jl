#=
julia --project=test
using Revise; include(joinpath("test", "DataLayouts", "data2d.jl"))
=#
using Test
using ClimaComms
using ClimaCore.DataLayouts
using StaticArrays
using ClimaCore.DataLayouts: check_basetype, get_struct, set_struct!, slab_index

device = ClimaComms.device()
ArrayType = ClimaComms.array_type(device)
@testset "check_basetype" begin
    @test_throws Exception check_basetype(Real, Float64)
    @test_throws Exception check_basetype(Float64, Real)

    @test isnothing(check_basetype(Float64, Float64))
    @test isnothing(check_basetype(Float64, Complex{Float64}))

    @test_throws Exception check_basetype(Float32, Float64)
    @test_throws Exception check_basetype(Float64, Complex{Float32})

    @test isnothing(check_basetype(Float64, Tuple{}))
    @test isnothing(check_basetype(Tuple{}, Tuple{}))
    @test_throws Exception check_basetype(Tuple{}, Float64)

    @test isnothing(check_basetype(Int, Tuple{Int, Complex{Int}}))
    @test isnothing(check_basetype(Float64, typeof(SA[1.0 2.0; 3.0 4.0])))

    S = typeof((a = ((1.0, 2.0f0), (3.0, 4.0f0)), b = (5.0, 6.0f0)))
    @test isnothing(check_basetype(Tuple{Float64, Float32}, S))

    S = typeof(((), (1.0 + 2.0im, NamedTuple()), 3.0 + 4.0im, ()))
    @test isnothing(check_basetype(Float64, S))
    @test isnothing(check_basetype(Complex{Float64}, S))
end

@testset "get_struct / set_struct!" begin
    array = [1.0, 2.0, 3.0]
    S = Tuple{Complex{Float64}, Float64}
    @test get_struct(array, S, Val(1), CartesianIndex(1)) == (1.0 + 2.0im, 3.0)
    set_struct!(array, (4.0 + 2.0im, 6.0), Val(1), CartesianIndex(1))
    @test array == [4.0, 2.0, 6.0]
    @test get_struct(array, S, Val(1), CartesianIndex(1)) == (4.0 + 2.0im, 6.0)
end

@testset "IJFH" begin
    Nij = 2 # number of nodal points
    Nh = 2 # number of elements
    FT = Float64
    S = Tuple{Complex{FT}, FT}
    data = IJFH{S}(ArrayType{FT}, rand; Nij, Nh)
    array = parent(data)
    @test getfield(data.:1, :array) == @view(array[:, :, 1:2, :])
    data_slab = slab(data, 1)
    @test data_slab[slab_index(2, 1)] ==
          (Complex(array[2, 1, 1, 1], array[2, 1, 2, 1]), array[2, 1, 3, 1])
    data_slab[slab_index(2, 1)] = (Complex(-1.0, -2.0), -3.0)
    @test array[2, 1, 1, 1] == -1.0
    @test array[2, 1, 2, 1] == -2.0
    @test array[2, 1, 3, 1] == -3.0

    subdata_slab = data_slab.:2
    @test subdata_slab[slab_index(2, 1)] == -3.0
    subdata_slab[slab_index(2, 1)] = -5.0
    @test array[2, 1, 3, 1] == -5.0

    @test sum(data.:1) ≈ Complex(sum(array[:, :, 1, :]), sum(array[:, :, 2, :])) atol =
        10eps()
    @test sum(x -> x[2], data) ≈ sum(array[:, :, 3, :]) atol = 10eps()
end

@testset "IJFH boundscheck" begin
    Nij = 1 # number of nodal points
    Nh = 2 # number of elements
    S = Tuple{Complex{Float64}, Float64}
    data = IJFH{S}(ArrayType{Float64}, zeros; Nij, Nh)

    @test_throws BoundsError slab(data, -1)
    @test_throws BoundsError slab(data, 3)
    @test_throws BoundsError slab(data, 1, -1)
    @test_throws BoundsError slab(data, 1, 3)

    # 2D Slab boundscheck
    sdata = slab(data, 1)
    @test_throws BoundsError sdata[slab_index(-1, 1)]
    @test_throws BoundsError sdata[slab_index(1, -1)]
    @test_throws BoundsError sdata[slab_index(2, 1)]
    @test_throws BoundsError sdata[slab_index(1, 2)]
end

@testset "IJFH type safety" begin
    Nij = 2 # number of nodal points per element
    Nh = 1 # number of elements

    # check that types of the same bitstype throw a conversion error
    SA = (a = 1.0, b = 2.0)
    SB = (c = 1.0, d = 2.0)

    data = IJFH{typeof(SA)}(ArrayType{Float64}, zeros; Nij, Nh)
    data_slab = slab(data, 1)
    ret = begin
        data_slab[slab_index(1, 1)] = SA
    end
    @test ret === SA
    @test data_slab[slab_index(1, 1)] isa typeof(SA)
    @test_throws MethodError data_slab[slab_index(1, 1)] = SB
end

@testset "2D slab broadcasting" begin
    Nij = 2 # number of nodal points
    Nh = 2 # number of elements
    S1 = Float64
    S2 = Float32
    data1 = IJFH{S1}(ArrayType{S1}, ones; Nij, Nh)
    data2 = IJFH{S2}(ArrayType{S2}, ones; Nij, Nh)

    for h in 1:Nh
        slab1 = slab(data1, h)
        slab2 = slab(data2, h)

        res = slab1 .+ slab2
        slab1 .= res .+ slab2
    end
    @test all(v -> v == S1(3), parent(data1))
end

@testset "broadcasting between data object + scalars" begin
    FT = Float64
    Nh = 2
    S = Complex{Float64}
    data1 = IJFH{S}(ArrayType{FT}, ones; Nij = 2, Nh)
    res = data1 .+ 1
    @test res isa IJFH{S}
    @test parent(res) ==
          FT[f == 1 ? 2 : 1 for i in 1:2, j in 1:2, f in 1:2, h in 1:2]

    @test sum(res) == Complex(16.0, 8.0)
    @test sum(Base.Broadcast.broadcasted(+, data1, 1)) == Complex(16.0, 8.0)
end

@testset "broadcasting assignment from scalar" begin
    FT = Float64
    S = Complex{FT}
    Nh = 3
    data = IJFH{S}(ArrayType{FT}; Nij = 2, Nh)
    data .= Complex(1.0, 2.0)
    @test parent(data) ==
          FT[f == 1 ? 1 : 2 for i in 1:2, j in 1:2, f in 1:2, h in 1:3]

    data .= 1
    @test parent(data) ==
          FT[f == 1 ? 1 : 0 for i in 1:2, j in 1:2, f in 1:2, h in 1:3]

end

@testset "broadcasting between data objects" begin
    FT = Float64
    Nh = 2
    S1 = Complex{Float64}
    S2 = Float64
    data1 = IJFH{S1}(ArrayType{FT}, ones; Nij = 2, Nh)
    data2 = IJFH{S2}(ArrayType{FT}, ones; Nij = 2, Nh)
    res = data1 .+ data2
    @test res isa IJFH{S1}
    @test parent(res) ==
          FT[f == 1 ? 2 : 1 for i in 1:2, j in 1:2, f in 1:2, h in 1:2]

    @test sum(res) == Complex(16.0, 8.0)
    @test sum(Base.Broadcast.broadcasted(+, data1, data2)) == Complex(16.0, 8.0)
end

@testset "broadcasting complicated function" begin
    FT = Float64
    S1 = NamedTuple{(:a, :b), Tuple{Complex{Float64}, Float64}}
    Nh = 2
    S2 = Float64
    data1 = IJFH{S1}(ArrayType{FT}, ones; Nij = 2, Nh)
    data2 = IJFH{S2}(ArrayType{FT}, ones; Nij = 2, Nh)

    f(a1, a2) = a1.a.re * a2 + a1.b
    res = f.(data1, data2)
    @test res isa IJFH{Float64}
    @test parent(res) == FT[2 for i in 1:2, j in 1:2, f in 1:1, h in 1:2]
end
