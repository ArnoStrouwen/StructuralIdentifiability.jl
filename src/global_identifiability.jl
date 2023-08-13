function extract_identifiable_functions_raw(
    io_equations::Dict{P, P},
    ode::ODE{P},
    known::Array{P, 1},
    with_states::Bool,
) where {P <: MPolyElem{fmpq}}
    coeff_lists = Dict(:with_states => Array{Array{P, 1}, 1}(), :no_states => Array{Array{P, 1}, 1}())
    bring = nothing
    if with_states
        @debug "Computing Lie derivatives"
        for f in states_generators(ode, io_equations)
            num, den = unpack_fraction(f)
            push!(coeff_lists[:with_states], [den, num])
        end
        bring = parent(first(first(coeff_lists[:with_states])))
    end

    @debug "Extracting coefficients"
    flush(stdout)
    nonparameters = filter(
        v -> !(var_to_str(v) in map(var_to_str, ode.parameters)),
        gens(parent(first(values(io_equations)))),
    )
    for eq in values(io_equations)
        eq_coefs = collect(values(extract_coefficients(eq, nonparameters)))
        if !isnothing(bring)
            eq_coefs = [parent_ring_change(c, bring) for c in eq_coefs]
        end
        push!(coeff_lists[:no_states], eq_coefs)
    end
    if isnothing(bring)
        bring = parent(first(first(coeff_lists[:no_states])))
    end
    for p in known
        if all(in.(map(var_to_str, vars(p)), [map(var_to_str, gens(bring))]))
            as_list = [one(bring), parent_ring_change(p, bring)]
            if any(in.(map(var_to_str, vars(p)), [map(var_to_str, nonparameters)]))
                push!(coeff_lists[:with_states], as_list)
            else
                push!(coeff_lists[:no_states], as_list)
            end
        else
            @debug "Known quantity $p cannot be casted and is thus dropped"
        end
    end
    return coeff_lists, bring
end

# ------------------------------------------------------------------------------

"""
    initial_identifiable_functions(ode; options...)

Returns the partially simplified identifiabile functions of the given ODE system.
These are presented by the coefficients of the IO-equations.

## Options

This functions takes the following optional arguments:
- `p`: probability of correctness
- `with_states`: Also report the identifiabile functions in states. Default is
  `false`. If this is `true`, the identifiable functions involving parameters only
   will be simplified
"""
function initial_identifiable_functions(
    ode::ODE{T};
    p::Float64,
    known::Array{T, 1} = Array{T, 1}(),
    with_states::Bool = false,
    var_change_policy = :default,
) where {T}
    @info "Computing IO-equations"
    ioeq_time =
        @elapsed io_equations = find_ioequations(ode; var_change_policy = var_change_policy)
    @debug "Sizes: $(map(length, values(io_equations)))"
    @info "Computed in $ioeq_time seconds" :ioeq_time ioeq_time
    _runtime_logger[:ioeq_time] = ioeq_time

    @info "Computing Wronskians"
    wrnsk_time = @elapsed wrnsk = wronskian(io_equations, ode)
    @info "Computed in $wrnsk_time seconds" :wrnsk_time wrnsk_time
    _runtime_logger[:wrnsk_time] = wrnsk_time

    dims = map(ncols, wrnsk)
    @info "Dimensions of the Wronskians $dims"

    rank_times = @elapsed wranks = map(rank, wrnsk)
    @debug "Dimensions of the Wronskians $dims"
    @debug "Ranks of the Wronskians $wranks"
    @info "Ranks of the Wronskians computed in $rank_times seconds" :rank_time rank_times
    _runtime_logger[:rank_time] = rank_times

    if any([dim != rk + 1 for (dim, rk) in zip(dims, wranks)])
        @warn "One of the Wronskians has corank greater than one, so the results of the algorithm will be valid only for multiexperiment identifiability. If you still  would like to assess single-experiment identifiability, we recommend using SIAN (https://github.com/alexeyovchinnikov/SIAN-Julia)"
    end

    id_funcs, bring = extract_identifiable_functions_raw(
        io_equations,
        ode,
        empty(ode.parameters),
        with_states,
    )

    if with_states
        @debug "Generators of identifiable functions involve states, the parameter-only part is getting simplified"
        no_states_simplified = simplified_generating_set(
            RationalFunctionField(id_funcs[:no_states]),
            p = p,
            seed = 42,
            strategy = (:gb,)
        )
        id_funcs[:no_states] = fractions_to_dennums(no_states_simplified)
    end

    if !with_states
        return id_funcs[:no_states], bring
    end
    return vcat(id_funcs[:with_states], id_funcs[:no_states]), bring
end

# ------------------------------------------------------------------------------

function check_identifiability(
    ode::ODE{P},
    funcs_to_check::Array{<:Any, 1};
    known::Array{P, 1} = Array{P, 1}(),
    p::Float64 = 0.99,
    var_change_policy = :default,
) where {P <: MPolyElem{fmpq}}
    states_needed = false
    for f in funcs_to_check
        num, den = unpack_fraction(f)
        if !all(v -> v in ode.parameters, union(vars(num), vars(den)))
            @info "Functions to check involve states"
            states_needed = true
            break
        end
    end

    half_p = 0.5 + p / 2
    identifiable_functions_raw, bring = initial_identifiable_functions(
        ode,
        known = known,
        p = p, 
        var_change_policy = var_change_policy, 
        with_states = states_needed
    )

    funcs_to_check = Vector{Generic.Frac{P}}(
        map(f -> parent_ring_change(f, bring) // one(bring), funcs_to_check),
    )

    return field_contains(
        RationalFunctionField(identifiable_functions_raw),
        funcs_to_check,
        half_p,
    )
end

function check_identifiability(
    ode::ODE{P};
    known::Array{P, 1} = Array{P, 1}(),
    p::Float64 = 0.99,
    var_change_policy = :default,
) where {P <: MPolyElem{fmpq}}
    return check_identifiability(ode, ode.parameters, known = known, p = p, var_change_policy = var_change_policy)
end

#------------------------------------------------------------------------------
"""
    assess_global_identifiability(ode::ODE{P}, p::Float64=0.99; var_change=:default) where P <: MPolyElem{fmpq}

Input:
- `ode` - the ODE model
- `known` - a list of functions in states which are assumed to be known and generic
- `p` - probability of correctness
- `var_change` - a policy for variable change (`:default`, `:yes`, `:no`), affects only the runtime

Output:
- a dictionary mapping each parameter to a boolean.

Checks global identifiability for parameters of the model provided in `ode`. Call this function to check global identifiability of all parameters automatically.
"""
function assess_global_identifiability(
    ode::ODE{P},
    known::Array{P, 1} = Array{P, 1}(),
    p::Float64 = 0.99;
    var_change = :default,
) where {P <: MPolyElem{fmpq}}
    result_list = assess_global_identifiability(
        ode,
        ode.parameters,
        known,
        p;
        var_change = var_change,
    )

    return Dict(param => val for (param, val) in zip(ode.parameters, result_list))
end

#------------------------------------------------------------------------------

"""
    assess_global_identifiability(ode, [funcs_to_check, p=0.99, var_change=:default])

Input:
- `ode` - the ODE model
- `funcs_to_check` - rational functions in parameters
- `known` - function in parameters that are assumed to be known and generic
- `p` - probability of correctness
- `var_change` - a policy for variable change (`:default`, `:yes`, `:no`),
                affects only the runtime

Output:
- array of length `length(funcs_to_check)` with true/false values for global identifiability
        or dictionary `param => Bool` if `funcs_to_check` are not given

Checks global identifiability of functions of parameters specified in `funcs_to_check`.
"""
function assess_global_identifiability(
    ode::ODE{P},
    funcs_to_check::Array{<:Any, 1},
    known::Array{P, 1} = Array{P, 1}(),
    p::Float64 = 0.99;
    var_change = :default,
) where {P <: MPolyElem{fmpq}}
    submodels = find_submodels(ode)
    if length(submodels) > 0
        @info "Note: the input model has nontrivial submodels. If the computation for the full model will be too heavy, you may want to try to first analyze one of the submodels. They can be produced using function `find_submodels`"
    end

    result = check_identifiability(ode, funcs_to_check, known = known, p = p, var_change_policy = var_change)

    return result
end
