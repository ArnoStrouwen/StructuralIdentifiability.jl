#------------------------------------------------------------------------------
"""
    check_field_membership(generators, rat_funcs, p, [method=:GroebnerBasis])

Checks whether given rational function belogn to a given field of rational functions
Inputs:
    - generators - a list of lists of polynomials. Each of the lists, say, [f1, ..., fn],
      defines generators f2/f1, ..., fn/f1. Let F be the field generated by all of them.
    - rat_funcs - list rational functions
    - p - a real number between 0 and 1, the probability of correctness
Output: a list L[i] of bools of length `length(rat_funcs)` such that L[i] is true iff
    the i-th function belongs to F. The whole result is correct with probability at least p
"""
function check_field_membership(
        generators::Array{<: Array{<: MPolyElem, 1}, 1},
        rat_funcs::Array{<: Any, 1},
        p::Float64;
        method=:GroebnerBasis)
    @debug "Finding pivot polynomials"
    pivots = map(plist -> plist[findmin(map(total_degree, plist))[2]], generators)
    @debug "\tDegrees are $(map(total_degree, pivots))"

    @debug "Sampling the point"
    flush(stdout)
    ring = parent(first(first(generators)))

    total_lcm = foldl(lcm, pivots)
    total_lcm = foldl(lcm, map(f -> unpack_fraction(f)[2], rat_funcs); init=total_lcm)
    degree = total_degree(total_lcm) + 1
    for (i, plist) in enumerate(generators)
        extra_degree = total_degree(total_lcm) - total_degree(pivots[i])
        degree = max(degree, extra_degree + max(map(total_degree, plist)...))
    end
    for f in rat_funcs
        num, den = unpack_fraction(f)
        degree = max(degree, total_degree(total_lcm) - total_degree(den) + total_degree(num))
    end
    @debug "\tBound for the degrees is $degree"
    total_vars = foldl(
        union, 
        map(plist -> foldl(union, map(poly -> Set(vars(poly)), plist)), generators)
    )
    @debug "\tThe total number of variables in $(length(total_vars))"

    sampling_bound = BigInt(3 * BigInt(degree)^(length(total_vars) + 3) * length(rat_funcs) * ceil(1 / (1 - p)))
    @debug "\tSampling from $(-sampling_bound) to $(sampling_bound)"
    point = map(v -> rand(-sampling_bound:sampling_bound), gens(ring))
    @debug "\tPoint is $point"

    @debug "Constructing the equations"
    eqs_sing = Array{Singular.spoly{Singular.n_Q}, 1}()
    ring_sing, vars_sing = Singular.PolynomialRing(
                               Singular.QQ, 
                               vcat(map(var_to_str, gens(ring)), ["sat_aux$i" for i in 1:length(generators)]);
                               ordering=:degrevlex
                           )

    for (i, component) in enumerate(generators)
        pivot = pivots[i]
        @debug "\tPivot polynomial is $(pivots)"
        eqs = []
        for poly in component
            push!(eqs, poly * evaluate(ring(pivot), point) - evaluate(ring(poly), point) * pivot)
        end
        append!(eqs_sing, map(p -> parent_ring_change(p, ring_sing), eqs))
        push!(
            eqs_sing,
            parent_ring_change(pivot, ring_sing) * vars_sing[end - i + 1] - 1
        )
    end

    @debug "Computing Groebner basis ($(length(eqs_sing)) equations)"
    flush(stdout)
    if method == :Singular
        gb = Singular.std(Singular.Ideal(ring_sing, eqs_sing))
    elseif method == :GroebnerBasis
        gb = GroebnerBasis.f4(Singular.Ideal(ring_sing, eqs_sing))
    else
        throw(Base.ArgumentError("Unknown method $method"))
    end

    @debug "Producing the result"
    flush(stdout)
    result = []
    for f in rat_funcs
        num, den = unpack_fraction(f)
        poly = num * evaluate(den, point) - den * evaluate(num, point)
        poly_sing = parent_ring_change(poly, ring_sing)
        push!(result, iszero(Singular.reduce(poly_sing, gb)))
    end
    return result
end

#------------------------------------------------------------------------------



function check_identifiability(
        io_equations::Array{P, 1}, 
        parameters::Array{P, 1},
        funcs_to_check::Array{<: Any, 1},
        p::Float64=0.99;
        method=:GroebnerBasis
    ) where P <: MPolyElem{fmpq}
    @debug "Extracting coefficients"
    flush(stdout)
    nonparameters = filter(v -> !(var_to_str(v) in map(var_to_str, parameters)), gens(parent(io_equations[1])))
    coeff_lists = Array{Array{P, 1}, 1}()
    for eq in io_equations
        push!(coeff_lists, collect(values(extract_coefficients(eq, nonparameters))))
    end
    for p in coeff_lists
        @debug sort(map(total_degree, p))
    end
    ring = parent(first(first(coeff_lists)))
    funcs_to_check = map(f -> parent_ring_change(f, ring), funcs_to_check)

    return check_field_membership(coeff_lists, funcs_to_check, p; method=method)
end

function check_identifiability(
        io_equation::P,
        parameters::Array{P, 1}, 
        funcs_to_check::Array{<: Any, 1}, 
        p::Float64=0.99; 
        method=:GroebnerBasis
    ) where P <: MPolyElem{fmpq}
    return check_identifiability([io_equation], parameters, funcs_to_check, p; method=method)
end

function check_identifiability(io_equations::Array{P, 1}, parameters::Array{P, 1}, p::Float64=0.99; method=:GroebnerBasis) where P <: MPolyElem{fmpq}
    check_identifiability(io_equations, parameters, parameters, p; method=method)
end

function check_identifiability(io_equation::P, parameters::Array{P, 1}, p::Float64=0.99; method=:GroebnerBasis) where P <: MPolyElem{fmpq}
    return check_identifiability([io_equation], parameters, p; method=method)
end

#------------------------------------------------------------------------------

"""
    assess_global_identifiability(ode, [funcs_to_check, p=0.99, var_change=:default, gb_method=:GroebnerBasis])

Checks global identifiability of given functions of parameters
Input:
    - ode - the ODE model
    - funcs_to_check - rational functions in parameters
    - p - probability of correctness
    - var_change - a policy for variable change (default, yes, no),
                   affects only the runtime
    - gb_method - library used for Groebner bases (GroebnerBasis, Singular)
Output: array of length  |funcs_to_check| with true/false values for global identifiability
        or dictionary param => Bool if funcs_to_check are not given
"""
function assess_global_identifiability(
        ode::ODE{P},
        funcs_to_check::Array{<: Any, 1},
        p::Float64=0.99;
        var_change=:default,
        gb_method=:GroebnerBasis
    ) where P <: MPolyElem{fmpq}
    @info "Computing IO-equations"
    ioeq_time = @elapsed io_equations = find_ioequations(ode; var_change_policy=var_change)
    @debug "Sizes: $(map(length, values(io_equations)))"
    @info "Computed in $ioeq_time seconds"

    @info "Computing Wronskians"
    wrnsk_time = @elapsed wrnsk = wronskian(io_equations, ode)
    @info "Computed in $wrnsk_time seconds"
    dims = map(ncols, wrnsk)
    @debug "Dimensions of the wronskians $dims"
    rank_times = @elapsed wranks = map(rank, wrnsk)
    @debug "Dimensions of the wronskians $dims"
    @debug "Ranks of the wronskians $wranks"
    @info "Ranks of the Wronskians computed in $rank_times seconds"
    if any([dim != rk + 1 for (dim, rk) in zip(dims, wranks)])
        @warn "One of the Wronskians has corank greater than one, so the results of the algorithm will be valid only for multiexperiment identifiability. If you still  would like to assess single-experiment identifiability, we recommend using SIAN (https://github.com/alexeyovchinnikov/SIAN-Julia)"
    end

    @info "Assessing global identifiability using the coefficients of the io-equations"
    check_time = @elapsed result = check_identifiability(collect(values(io_equations)), ode.parameters, funcs_to_check, p; method=gb_method)
    @info "Computed in $check_time seconds"

    return result
end

#------------------------------------------------------------------------------

function assess_global_identifiability(
        ode::ODE{P},
        p::Float64=0.99; 
        var_change=:default,
        gb_method=:GroebnerBasis
    ) where P <: MPolyElem{fmpq}
    result_list = assess_global_identifiability(ode, ode.parameters, p; var_change=var_change, gb_method=gb_method)

    return Dict([param => val for (param, val) in zip(ode.parameters, result_list)])
end

#------------------------------------------------------------------------------
# Experimental functionality

function (F::Singular.N_FField)(a::fmpq)
    return F(numerator(a)) // F(denominator(a))
end

"""
    simplify_field_generators(generators)

Simplifies generators of a subfield of rational functions
Inputs:
    - generators - a list of lists of polynomials. Each of the lists, say, [f1, ..., fn],
      defines generators f2/f1, ..., fn/f1. Let F be the field generated by all of them.
Output: simplified generators of F
"""
function simplify_field_generators(generators::Array{<: Array{<: MPolyElem, 1}, 1})
    @debug "Finding pivot polynomials"
    pivots = map(plist -> plist[findmin(map(total_degree, plist))[2]], generators)
    @debug "\tDegrees are $(map(total_degree, pivots))"

    total_vars = foldl(
        union, 
        map(plist -> foldl(union, map(poly -> Set(vars(poly)), plist)), generators)
    )
    total_vars = collect(total_vars)

    @debug "Constructing the equations"
    F, Fvars = Singular.FunctionField(Singular.QQ, map(var_to_str, total_vars))
    eqs_sing = Array{Singular.spoly{Singular.n_transExt}, 1}()
    ring_sing, vars_sing = Singular.PolynomialRing(
                               F, 
                               vcat(
                                    map(v -> var_to_str(v), total_vars),
                                    ["sat_aux$i" for i in 1:length(generators)]
                               );
                               ordering=:degrevlex
                           )
    base_to_coef = Dict(vars_sing[i] => Fvars[i] for i in 1:length(Fvars))

    for (i, component) in enumerate(generators)
        pivot = pivots[i]
        pivot_base = parent_ring_change(pivot, ring_sing)
        pivot_coef = eval_at_dict(pivot_base, base_to_coef)
        @debug "\tPivot polynomial is $(pivots)"
        for p in component
            p_base = parent_ring_change(p, ring_sing)
            p_coef = eval_at_dict(p_base, base_to_coef)
            push!(eqs_sing, p_base * pivot_coef - p_coef * pivot_base)
        end
        push!(
            eqs_sing,
            pivot_base * vars_sing[end - i + 1] - 1
        )
    end

    @debug "Computing Groebner basis ($(length(eqs_sing)) equations)"
    flush(stdout)
    gb = Singular.std(Singular.Ideal(ring_sing, eqs_sing))
    
    result = Set()

    for poly in gens(gb)
        denom = first(coeffs(poly))
        for c in coeffs(poly)
            if !(-c // denom in result)
                push!(result, c // denom)
            end
        end
    end

    return result
end

#------------------------------------------------------------------------------

"""
    extract_identifiable_functions(io_equations, parameters)

For the io_equation and the list of all parameter variables, returns a dictionary
var => whether_globally_identifiable
method can be "Singular" or "GroebnerBasis" yielding using Singular.jl or GroebnerBasis.jl
"""
function extract_identifiable_functions(io_equations::Array{P, 1}, parameters::Array{P, 1}) where P <: MPolyElem{fmpq}
    @debug "Extracting coefficients"
    flush(stdout)
    nonparameters = filter(v -> !(var_to_str(v) in map(var_to_str, parameters)), gens(parent(io_equations[1])))
    coeff_lists = Array{Array{P, 1}, 1}()
    for eq in io_equations
        push!(coeff_lists, collect(values(extract_coefficients(eq, nonparameters))))
    end
    for p in coeff_lists
        @debug sort(map(total_degree, p))
    end

    return simplify_field_generators(coeff_lists)
end


