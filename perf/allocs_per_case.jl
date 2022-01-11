# Launch with `julia --project --track-allocation=user`
if !("." in LOAD_PATH)
    push!(LOAD_PATH, ".")
end
import Profile

case_name = ENV["ALLOCATION_CASE_NAME"]
ENV["CI_PERF_SKIP_RUN"] = true # we only need haskey(ENV, "CI_PERF_SKIP_RUN") == true
include(case_name)
@info "Recording allocations for $case_name"

rhs!(dYdt, Y, nothing, 0.0) # compile first
Profile.clear_malloc_data()
rhs!(dYdt, Y, nothing, 0.0)

# Quit julia (which generates .mem files), then call
#=
import Coverage
allocs = Coverage.analyze_malloc("src")
=#
