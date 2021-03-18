using Logging

include("../src/StructuralIdentifiability.jl")
using .StructuralIdentifiability
using .StructuralIdentifiability: _runtime_logger, ODE

logger = Logging.SimpleLogger(stdout, Logging.Info)
global_logger(logger)

include("benchmarks.jl")

runtimes = Dict()
TIME_CATEGORIES = [:loc_time, :glob_time, :ioeq_time, :wrnsk_time, :rank_time, :check_time, :total]
NUM_RUNS = 3

for bmark in benchmarks
    name = bmark[:name]
    if (:skip in keys(bmark)) && bmark[:skip]
        @info "Skipping $name"
        continue
    end
    @info "Processing $name"
    runtimes[bmark[:name]] = Dict(c => 0. for c in TIME_CATEGORIES)
    for _ in 1:NUM_RUNS
        runtimes[name][:total] += @elapsed assess_identifiability(bmark[:ode])
        for cat in TIME_CATEGORIES[1:end - 1]
            runtimes[name][cat] += _runtime_logger[cat]
        end
    end
    for k in keys(runtimes[name])
        runtimes[name][k] = runtimes[name][k] / NUM_RUNS
    end
end

println(runtimes)