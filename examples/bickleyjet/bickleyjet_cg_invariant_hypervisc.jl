using ClimaComms
using LinearAlgebra

import ClimaCore:
    Domains,
    Fields,
    Geometry,
    Meshes,
    Operators,
    Spaces,
    Topologies,
    Quadratures,
    DataLayouts
using OrdinaryDiffEqSSPRK: ODEProblem, solve, SSPRK33

using Logging
ClimaComms.@import_required_backends
const context = ClimaComms.context()
usempi = context isa ClimaComms.MPICommsContext
if usempi
    const pid, nprocs = ClimaComms.init(context)
    const iamroot = ClimaComms.iamroot(context)
    iamroot && println("running distributed simulation using $nprocs processes")
    # log output only from root process
    logger_stream = iamroot ? stderr : devnull

    prev_logger = global_logger(ConsoleLogger(logger_stream, Logging.Info))
    atexit() do
        global_logger(prev_logger)
    end
else
    import TerminalLoggers
    global_logger(TerminalLoggers.TerminalLogger())
end

const parameters = (
    ϵ = 0.1,  # perturbation size for initial condition
    l = 0.5, # Gaussian width
    k = 0.5, # Sinusoidal wavenumber
    ρ₀ = 1.0, # reference density
    c = 2,
    g = 10,
)

domain = Domains.RectangleDomain(
    Domains.IntervalDomain(
        Geometry.XPoint(-2π),
        Geometry.XPoint(2π),
        periodic = true,
    ),
    Domains.IntervalDomain(
        Geometry.YPoint(-2π),
        Geometry.YPoint(2π),
        periodic = true,
    ),
)
n1, n2 = 16, 16
Nq = 4
quad = Quadratures.GLL{Nq}()
mesh = Meshes.RectilinearMesh(domain, n1, n2)
grid_topology = Topologies.Topology2D(context, mesh)
if usempi
    global_grid_topology =
        Topologies.Topology2D(ClimaComms.SingletonCommsContext(), mesh)
    space = Spaces.SpectralElementSpace2D(grid_topology, quad)
    global_space = Spaces.SpectralElementSpace2D(global_grid_topology, quad)
else
    global_space = space = Spaces.SpectralElementSpace2D(grid_topology, quad)
end

function init_state(local_geometry, p)
    coord = local_geometry.coordinates
    x, y = coord.x, coord.y
    # set initial state
    ρ = p.ρ₀

    # set initial velocity
    U₁ = cosh(y)^(-2)

    # Ψ′ = exp(-(x2 + p.l / 10)^2 / 2p.l^2) * cos(p.k * x) * cos(p.k * y)
    # Vortical velocity fields (u₁′, u₂′) = (-∂²Ψ′, ∂¹Ψ′)
    gaussian = exp(-(y + p.l / 10)^2 / 2p.l^2)
    u₁′ = gaussian * (y + p.l / 10) / p.l^2 * cos(p.k * x) * cos(p.k * y)
    u₁′ += p.k * gaussian * cos(p.k * x) * sin(p.k * y)
    u₂′ = -p.k * gaussian * sin(p.k * x) * cos(p.k * y)

    u = Geometry.Covariant12Vector(
        Geometry.UVVector(U₁ + p.ϵ * u₁′, p.ϵ * u₂′),
        local_geometry,
    )

    # set initial tracer
    θ = sin(p.k * y)
    return (ρ = ρ, u = u, ρθ = ρ * θ)
end

y0 = init_state.(Fields.local_geometry_field(space), Ref(parameters))

ghost_buffer = Spaces.create_dss_buffer(y0)


function energy(state, p, local_geometry)
    ρ, u = state.ρ, state.u
    return ρ * Geometry._norm_sqr(u, local_geometry) / 2 + p.g * ρ^2 / 2
end

function rhs!(dydt, y, _, t)
    space = axes(y)
    c = sqrt(parameters.g * parameters.ρ₀)
    D₄ = 0.0015 * c * Spaces.node_horizontal_length_scale(space)^3 # hyperdiffusion coefficient

    g = parameters.g

    sdiv = Operators.Divergence()
    wdiv = Operators.WeakDivergence()
    grad = Operators.Gradient()
    wgrad = Operators.WeakGradient()
    curl = Operators.Curl()
    wcurl = Operators.WeakCurl()

    # compute hyperviscosity first
    @. dydt.u =
        wgrad(sdiv(y.u)) -
        Geometry.Covariant12Vector(wcurl(Geometry.Covariant3Vector(curl(y.u))))
    @. dydt.ρθ = wdiv(grad(y.ρθ / y.ρ))

    Spaces.weighted_dss!(dydt, ghost_buffer)

    @. dydt.u =
        -D₄ * (
            wgrad(sdiv(dydt.u)) - Geometry.Covariant12Vector(
                wcurl(Geometry.Covariant3Vector(curl(dydt.u))),
            )
        )
    @. dydt.ρθ = -D₄ * wdiv(y.ρ * grad(dydt.ρθ))

    # add in pieces
    @. begin
        dydt.ρ = -wdiv(y.ρ * y.u)
        dydt.u += -grad(g * y.ρ + norm(y.u)^2 / 2) + y.u × curl(y.u)
        dydt.ρθ += -wdiv(y.ρθ * y.u)
    end
    Spaces.weighted_dss!(dydt, ghost_buffer)
    return dydt
end

dydt = similar(y0)
rhs!(dydt, y0, nothing, 0.0)
# Solve the ODE operator
prob = ODEProblem(rhs!, y0, (0.0, 80.0))
#prob = ODEProblem(rhs!, y0, (0.0, 2.0))

sol = solve(
    prob,
    SSPRK33(),
    dt = 0.02,
    saveat = collect(0.0:1.0:80.0),
    progress = true,
    progress_message = (dt, u, p, t) -> t,
)

sol_global = []
if usempi
    for sol_step in sol.u
        sol_step_values_global =
            DataLayouts.gather(context, Fields.field_values(sol_step))
        if ClimaComms.iamroot(context)
            sol_step_global = Fields.Field(sol_step_values_global, global_space)
            push!(sol_global, sol_step_global)
        end
    end
end

ENV["GKSwstype"] = "nul"
using ClimaCorePlots, Plots
Plots.GRBackend()
dir = "cg_invariant_hypervisc"
path = joinpath(@__DIR__, "output", dir)
mkpath(path)
solution = usempi ? sol_global : sol.u

function total_energy(y, parameters)
    sum(energy.(y, Ref(parameters), Fields.local_geometry_field(global_space)))
end

if !usempi || (usempi && ClimaComms.iamroot(context))
    anim = Plots.@animate for u in solution
        Plots.plot(u.ρθ, clim = (-1, 1))
    end
    Plots.mp4(anim, joinpath(path, "tracer.mp4"), fps = 10)

    Es = [total_energy(u, parameters) for u in solution]

    Plots.png(Plots.plot(Es), joinpath(path, "energy.png"))

    function linkfig(figpath, alt = "")
        # buildkite-agent upload figpath
        # link figure in logs if we are running on CI
        if get(ENV, "BUILDKITE", "") == "true"
            artifact_url = "artifact://$figpath"
            print("\033]1338;url='$(artifact_url)';alt='$(alt)'\a\n")
        end
    end

    linkfig(
        relpath(joinpath(path, "energy.png"), joinpath(@__DIR__, "../..")),
        "Total Energy",
    )
end
