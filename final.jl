using JuMP
using Gurobi
using Random
using LinearAlgebra
using Statistics
using Printf
using Plots
using Pkg
using XLSX
# ============================================================================
# Structure de données pour l'instance
# ============================================================================

struct Instance
    n::Int                          
    K::Int                          
    B::Float64                      
    edges::Vector{Tuple{Int,Int}}   
    l::Dict{Tuple{Int,Int},Float64} 
    l_hat::Vector{Float64}          
    w::Vector{Float64}              
    L::Float64                      
    W::Float64                      
    W_v::Vector{Float64}            
    coordinates::Matrix{Float64}    
end

# ============================================================================
# Lecture de fichiers d'instance
# ============================================================================

function parse_vector_line(line::AbstractString)
    line = replace(line, "[" => "", "]" => "")
    parts = split(line, ",")
    return [parse(Float64, strip(p)) for p in parts]
end

function parse_coordinates(lines::Vector{String}, start_idx::Int)
    coords = Float64[]
    idx = start_idx
    while idx <= length(lines)
        line = strip(lines[idx])
        if isempty(line) || !occursin(r"[\d\.]", line)
            break
        end
        line = replace(line, "[" => "", "]" => "", ";" => "")
        parts = split(line)
        for p in parts
            p_clean = strip(p)
            if !isempty(p_clean)
                push!(coords, parse(Float64, p_clean))
            end
        end
        idx += 1
    end
    n = div(length(coords), 2)
    return reshape(coords, 2, n)'
end

function read_instance_file(filepath::String)
    println("📂 Lecture du fichier : $filepath")
    
    if !isfile(filepath)
        error("Le fichier $filepath n'existe pas")
    end
    
    lines = readlines(filepath)
    
    n, L, W, K, B = 0, 0.0, 0.0, 0, 0.0
    w_v = Float64[]
    W_v_vec = Float64[]
    lh = Float64[]
    coordinates = Matrix{Float64}(undef, 0, 2)
    
    i = 1
    while i <= length(lines)
        line = strip(lines[i])
        
        if isempty(line)
            i += 1
            continue
        end
        
        if startswith(line, "n =")
            n = parse(Int, split(line, "=")[2])
        elseif startswith(line, "L =")
            L = parse(Float64, split(line, "=")[2])
        elseif startswith(line, "W =")
            W = parse(Float64, split(line, "=")[2])
        elseif startswith(line, "K =")
            K = parse(Int, split(line, "=")[2])
        elseif startswith(line, "B =")
            B = parse(Float64, split(line, "=")[2])
        elseif startswith(line, "w_v =")
            vec_str = split(line, "=", limit=2)[2]
            w_v = parse_vector_line(vec_str)
        elseif startswith(line, "W_v =")
            vec_str = split(line, "=", limit=2)[2]
            W_v_vec = parse_vector_line(vec_str)
        elseif startswith(line, "lh =")
            vec_str = split(line, "=", limit=2)[2]
            lh = parse_vector_line(vec_str)
        elseif startswith(line, "coordinates =")
            coordinates = parse_coordinates(lines, i + 1)
            break
        end
        
        i += 1
    end
    
    if n == 0 || K == 0
        error("Paramètres n et K requis")
    end
    
    if length(w_v) != n
        error("w_v doit avoir $n éléments, trouvé $(length(w_v))")
    end
    
    if length(W_v_vec) != n
        error("W_v doit avoir $n éléments, trouvé $(length(W_v_vec))")
    end
    
    if length(lh) != n
        error("lh doit avoir $n éléments, trouvé $(length(lh))")
    end
    
    if size(coordinates, 1) != n
        error("coordinates doit avoir $n lignes, trouvé $(size(coordinates, 1))")
    end
    
    println("✓ Fichier lu avec succès")
    println("  n=$n, K=$K, L=$L, W=$W, B=$B")
    
    edges = Tuple{Int,Int}[]
    l = Dict{Tuple{Int,Int},Float64}()
    
    for i in 1:n
        for j in (i+1):n
            edge = (i, j)
            push!(edges, edge)
            dist = sqrt((coordinates[i,1] - coordinates[j,1])^2 + 
                       (coordinates[i,2] - coordinates[j,2])^2)
            l[edge] = dist
        end
    end
    
    println("  $(length(edges)) arêtes créées (graphe complet)")
    
    return Instance(n, K, B, edges, l, lh, w_v, L, W, W_v_vec, coordinates)
end

# ============================================================================
# CALCUL DU PRIX DE LA ROBUSTESSE (PR)
# ============================================================================

"""
    calculate_robustness_price(obj_robust, obj_static)

Calcule le Prix de la Robustesse (PR) selon la formule:
PR = (Obj_Robuste - Obj_Statique) / Obj_Statique × 100

Retourne le PR en pourcentage.
"""
function calculate_robustness_price(obj_robust::Float64, obj_static::Float64)
    if obj_static == 0.0 || obj_static == Inf
        return Inf
    end
    return ((obj_robust - obj_static) / obj_static) * 100.0
end

# ============================================================================
# GÉNÉRATION DE DIAGRAMMES DE PERFORMANCES
# ============================================================================

"""
    plot_performance_profile(all_results, output_file="performance_profile.png")

Génère un diagramme de performances comme dans la documentation.
Le diagramme montre le nombre d'instances résolues en fonction du temps (courbes en escalier).

# Arguments
- `all_results`: Dict{String, Vector} où chaque méthode a un vecteur de (temps, statut) par instance
- `output_file`: Nom du fichier de sortie (PNG)
"""
function plot_performance_profile(all_results::Dict, output_file::String="performance_profile.png")
    # Créer le graphique
    p = plot(
        xlabel="Temps (s)",
        ylabel="Nombre d'instances résolues",
        title="Diagramme de Performances",
        legend=:bottomright,
        size=(900, 600),
        grid=true,
        gridstyle=:dash,
        gridalpha=0.3
    )
    
    # Couleurs et styles pour chaque méthode
    colors = [:blue, :green, :orange, :purple, :red, :brown]
    markers = [:circle, :square, :diamond, :utriangle, :star5, :cross]
    
    method_names = collect(keys(all_results))
    
    # Pour chaque méthode, créer la courbe en escalier
    for (idx, method) in enumerate(method_names)
        results = all_results[method]
        
        # Trier par temps
        sorted_results = sort(results, by=x -> x[1])
        
        # Construire les points de la courbe en escalier
        times = [0.0]
        counts = [0]
        
        for (i, (t, status)) in enumerate(sorted_results)
            if status == MOI.OPTIMAL || status == MOI.TIME_LIMIT
                push!(times, t)
                push!(counts, i)
            end
        end
        
        # Ajouter point final
        if length(times) > 1
            max_time = maximum([maximum([r[1] for r in all_results[m]]) for m in method_names])
            push!(times, max_time * 1.1)
            push!(counts, counts[end])
        end
        
        # Tracer la courbe
        plot!(p, times, counts,
              label=method,
              linewidth=2.5,
              color=colors[mod1(idx, length(colors))],
              marker=markers[mod1(idx, length(markers))],
              markersize=5,
              markerstrokewidth=0,
              linestyle=:solid)
    end
    
    # Sauvegarder
    savefig(p, output_file)
    println("  📊 Diagramme de performances sauvegardé: $output_file")
    
    return p
end

"""
    plot_performance_profile_single(results_dict, output_file="performance_profile.png")

Version pour une seule instance - génère un diagramme simplifié.
"""
function plot_performance_profile_single(results_dict::Dict, output_file::String="performance_profile.png")
    methods = collect(keys(results_dict))
    
    # Créer le graphique
    p = plot(
        xlabel="Temps (s)",
        ylabel="Instance résolue",
        title="Diagramme de Performances (Instance Unique)",
        legend=:right,
        size=(900, 600),
        grid=true,
        ylim=(0, 1.2)
    )
    
    colors = [:blue, :green, :orange, :purple, :red, :brown]
    
    # Pour chaque méthode
    for (idx, method) in enumerate(methods)
        obj, time_val, gap, status = results_dict[method]
        
        # Point de succès
        success = (status == MOI.OPTIMAL || status == MOI.TIME_LIMIT) ? 1 : 0
        
        # Courbe en escalier
        plot!(p, [0, time_val, time_val * 1.5], [0, 0, success],
              label=method,
              linewidth=3,
              color=colors[mod1(idx, length(colors))],
              marker=:circle,
              markersize=6,
              linestyle=:solid)
    end
    
    savefig(p, output_file)
    println("  📊 Diagramme de performances sauvegardé: $output_file")
    
    return p
end

"""
    plot_comparative_bar_chart(results_dict, output_file="comparison_bar.png")

Génère un diagramme en barres comparant temps et objectifs des méthodes.
"""
function plot_comparative_bar_chart(results_dict::Dict, output_file::String="comparison_bar.png")
    methods = collect(keys(results_dict))
    objectives = [results_dict[m][1] for m in methods]
    times = [results_dict[m][2] for m in methods]
    
    # Créer deux sous-graphiques
    p1 = bar(methods, objectives, 
             title="Valeurs Objectives",
             ylabel="Objectif",
             legend=false,
             color=:lightblue)
    
    p2 = bar(methods, times,
             title="Temps de Résolution",
             ylabel="Temps (s)",
             legend=false,
             color=:lightgreen)
    
    p = plot(p1, p2, layout=(1, 2), size=(1000, 400))
    
    savefig(p, output_file)
    println("  📊 Diagramme comparatif sauvegardé: $output_file")
    
    return p
end

# ============================================================================
# UTILITAIRES D'AFFICHAGE
# ============================================================================

function print_solution(model, data::Instance, method_name::String)
    status = termination_status(model)
    
    println("\n┌─────────────────────────────────────────────────────────┐")
    println("│  Solution $method_name")
    println("└─────────────────────────────────────────────────────────┘")
    
    # --- CORRECTION ICI : On vérifie si une solution primale existe ---
    if !has_values(model)
        println("  ⚠️  Statut: $status")
        println("  ❌  Aucune solution entière trouvée (ou problème infaisable/unbounded).")
        return
    end
    # ------------------------------------------------------------------
    
    x_val = value.(model[:x])
    partitions = []
    
    for k in 1:data.K
        group = [i for i in 1:data.n if x_val[i,k] > 0.5]
        if !isempty(group)
            push!(partitions, sort(group))
        end
    end
    
    if !isempty(partitions)
        println("  📊 Partitions:")
        for (k, group) in enumerate(partitions)
            weight = sum(data.w[i] for i in group)
            println("     P$k = {$(join(group, ", "))} → poids: $(round(weight, digits=2))")
        end
    end
    
    obj_val = objective_value(model)
    println("  🎯 Objectif: $(round(obj_val, digits=4))")
    
    try
        gap = MOI.get(model, MOI.RelativeGap())
        if gap < Inf
            println("  📉 Gap: $(round(gap * 100, digits=2))%")
        end
    catch
    end
    
    println("  ✅ Statut: $status")
end

function print_comparison_table(results::Dict)
    println("\n" * "="^120)
    println(" " ^ 45 * "TABLEAU COMPARATIF FINAL")
    println("="^120)
    
    @printf "%-25s | %15s | %12s | %12s | %12s | %15s | %12s\n" "Méthode" "Obj. Value" "Temps (s)" "Gap (%)" "Statut" "Amélioration" "PR (%)"
    println("-"^120)
    
    base_obj = haskey(results, "Statique") ? results["Statique"][1] : nothing
    
    method_order = ["Statique", "Dualisation", "Plans Coupants", "Branch-and-Cut", "Heuristique"]
    
    for method_name in method_order
        if haskey(results, method_name)
            obj, time_val, gap, status = results[method_name]
            
            improvement = ""
            pr = ""
            if base_obj !== nothing && method_name != "Statique"
                if base_obj > 0
                    pct = ((obj - base_obj) / base_obj) * 100
                    improvement = @sprintf("%+.2f%%", pct)
                    pr_val = calculate_robustness_price(obj, base_obj)
                    pr = @sprintf("%.2f%%", pr_val)
                end
            else
                improvement = "-"
                pr = "-"
            end
            
            gap_str = gap < Inf ? @sprintf("%.4f", gap * 100) : "N/A"
            
            status_short = if status == MOI.OPTIMAL
                "✓ Optimal"
            elseif status == MOI.TIME_LIMIT
                "⏱ Timeout"
            else
                "⚠ $(status)"
            end
            
            @printf "%-25s | %15.4f | %12.2f | %12s | %12s | %15s | %12s\n" method_name obj time_val gap_str status_short improvement pr
        end
    end
    
    println("="^120)
    
    if length(results) >= 2
        robust_vals = [v[1] for (k, v) in results if k != "Statique" && v[1] < Inf]
        if length(robust_vals) >= 2
            diff = maximum(robust_vals) - minimum(robust_vals)
            if diff < 1e-4
                println("\n✅ Convergence parfaite des méthodes robustes (écart < 0.0001)")
            elseif diff < 1.0
                println("\n✓ Bonne convergence des méthodes robustes (écart: $(round(diff, digits=4)))")
            else
                println("\n⚠️  Écart significatif entre les méthodes robustes: $(round(diff, digits=2))")
            end
        end
    end
end

# ============================================================================
# BRISURE DE SYMÉTRIE
# ============================================================================

function add_symmetry_breaking_constraints!(model, data::Instance)
    n, K = data.n, data.K
    x = model[:x]
    
    @constraint(model, sym_first_node, x[1, 1] == 1)
    
    for k in 1:(K-1)
        for i in 2:n
            @constraint(model, 
                sum(x[j, k] for j in 1:i) >= x[i, k+1]
            )
        end
    end
    
    println("  🔒 Contraintes de brisure de symétrie ajoutées")
end

# ============================================================================
# WARM START
# ============================================================================

function set_warm_start!(model, data::Instance, reference_model)
    if !has_values(reference_model)
        println("  ⚠️  Pas de solution de référence disponible pour le warm start")
        return false
    end
    
    try
        x_ref = value.(reference_model[:x])
        y_ref = value.(reference_model[:y])
        
        x = model[:x]
        y = model[:y]
        
        for i in 1:data.n
            for k in 1:data.K
                set_start_value(x[i, k], x_ref[i, k])
            end
        end
        
        for e in data.edges
            set_start_value(y[e], y_ref[e])
        end
        
        if haskey(object_dictionary(model), :z)
            z_ref = value(reference_model[:z])
            set_start_value(model[:z], z_ref)
        end
        
        println("  🚀 Solution initiale fournie (warm start activé)")
        return true
    catch e
        println("  ⚠️  Erreur lors du warm start: $e")
        return false
    end
end

# ============================================================================
# HEURISTIQUES POUR LES SOUS-PROBLÈMES
# ============================================================================

function heuristic_separation_objective(data::Instance, y_val::Dict)
    E = data.edges
    
    scores = [(e, (data.l_hat[e[1]] + data.l_hat[e[2]]) * y_val[e], 3.0) for e in E]
    sort!(scores, by=x -> x[2], rev=true)
    
    δ_solution = Dict{Tuple{Int,Int}, Float64}()
    total_deviation = 0.0
    remaining_budget = data.L
    objective_value = 0.0
    
    for (edge, impact, max_dev) in scores
        if remaining_budget <= 0
            break
        end
        
        deviation = min(max_dev, remaining_budget)
        δ_solution[edge] = deviation
        remaining_budget -= deviation
        
        objective_value += impact * deviation
    end
    
    for e in E
        if !haskey(δ_solution, e)
            δ_solution[e] = 0.0
        end
    end
    
    return (objective_value, δ_solution)
end

function heuristic_separation_feasibility(data::Instance, x_val::Matrix{Float64}, k::Int)
    n = data.n
    
    scores = [(i, data.w[i] * x_val[i, k], data.W_v[i]) for i in 1:n]
    sort!(scores, by=x -> x[2], rev=true)
    
    δ_solution = zeros(Float64, n)
    remaining_budget = data.W
    
    for (node, impact, max_dev) in scores
        if remaining_budget <= 0
            break
        end
        
        deviation = min(max_dev, remaining_budget)
        δ_solution[node] = deviation
        remaining_budget -= deviation
    end
    
    total_weight = sum(data.w[i] * x_val[i, k] * (1 + δ_solution[i]) for i in 1:n)
    
    return (total_weight, δ_solution)
end

function separation_objective(data::Instance, y_val::Dict; use_heuristic::Bool=true)
    E = data.edges
    
    if use_heuristic
        heur_obj, heur_sol = heuristic_separation_objective(data, y_val)
        
        if heur_obj > 1e-6
            return (heur_obj, heur_sol)
        end
    end
    
    GRB_ENV = Gurobi.Env()
    model = Model(() -> Gurobi.Optimizer(GRB_ENV))
    set_optimizer_attribute(model, "OutputFlag", 0)
    set_optimizer_attribute(model, "TimeLimit", 10)
    
    @variable(model, 0 <= δ[e in E] <= 3.0)
    @objective(model, Max, sum((data.l_hat[e[1]] + data.l_hat[e[2]]) * y_val[e] * δ[e] for e in E))
    @constraint(model, sum(δ[e] for e in E) <= data.L)
    
    optimize!(model)
    
    if termination_status(model) == MOI.OPTIMAL || termination_status(model) == MOI.TIME_LIMIT
        return (objective_value(model), Dict(e => value(δ[e]) for e in E))
    else
        return (0.0, nothing)
    end
end

function separation_feasibility(data::Instance, x_val::Matrix{Float64}, k::Int; use_heuristic::Bool=true)
    n = data.n
    
    if use_heuristic
        heur_weight, heur_sol = heuristic_separation_feasibility(data, x_val, k)
        
        if heur_weight > data.B + 1e-6
            return (heur_weight, heur_sol)
        end
    end
    
    GRB_ENV = Gurobi.Env()
    model = Model(() -> Gurobi.Optimizer(GRB_ENV))
    set_optimizer_attribute(model, "OutputFlag", 0)
    set_optimizer_attribute(model, "TimeLimit", 10)
    
    @variable(model, 0 <= δ[i=1:n] <= data.W_v[i])
    
    @objective(model, Max, 
        sum(data.w[i] * x_val[i,k] for i in 1:n) +       
        sum(data.w[i] * x_val[i,k] * δ[i] for i in 1:n)
    )
    
    @constraint(model, sum(δ[i] for i in 1:n) <= data.W)
    
    optimize!(model)
    
    if termination_status(model) == MOI.OPTIMAL || termination_status(model) == MOI.TIME_LIMIT
        return (objective_value(model), value.(δ))
    else
        return (0.0, nothing)
    end
end

# ============================================================================
# MÉTHODE 0 : Résolution STATIQUE (Baseline)
# ============================================================================

function solve_static(data::Instance; 
                     time_limit::Int=300, 
                     gap_limit::Float64=0.01,
                     verbose::Bool=false)
    if verbose
        println("\n" * "="^80)
        println(" " ^ 25 * "MÉTHODE 0 : RÉSOLUTION STATIQUE (BASELINE)")
        println("="^80)
    end
    
    GRB_ENV = Gurobi.Env()
    model = Model(() -> Gurobi.Optimizer(GRB_ENV))
    set_optimizer_attribute(model, "OutputFlag", verbose ? 1 : 0)
    set_optimizer_attribute(model, "TimeLimit", time_limit)
    set_optimizer_attribute(model, "MIPGap", gap_limit)
    
    n, K, B = data.n, data.K, data.B
    E = data.edges
    
    @variable(model, x[1:n, 1:K], Bin)
    @variable(model, y[e in E], Bin)
    
    @objective(model, Min, sum(data.l[e] * y[e] for e in E))
    
    @constraint(model, [i=1:n], sum(x[i,k] for k in 1:K) == 1)
    @constraint(model, [e in E, k in 1:K], y[e] >= x[e[1], k] + x[e[2], k] - 1)
    @constraint(model, [k=1:K], sum(data.w[i] * x[i,k] for i in 1:n) <= B)
    
    add_symmetry_breaking_constraints!(model, data)
    
    optimize!(model)
    
    if verbose
        print_solution(model, data, "Statique")
    end
    
    return model
end

# ============================================================================
# MÉTHODE 1 : Résolution Robuste par DUALISATION (Monolithique)
# ============================================================================

function solve_robust_dualization(data::Instance; 
                                 time_limit::Int=300, 
                                 gap_limit::Float64=0.01,
                                 warm_start_model=nothing,
                                 verbose::Bool=false)
    if verbose
        println("\n" * "="^80)
        println(" " ^ 25 * "MÉTHODE 1 : DUALISATION (MONOLITHIQUE)")
        println("="^80)
    end

    GRB_ENV = Gurobi.Env()
    model = Model(() -> Gurobi.Optimizer(GRB_ENV))
    set_optimizer_attribute(model, "OutputFlag", verbose ? 1 : 0)
    set_optimizer_attribute(model, "TimeLimit", time_limit)
    set_optimizer_attribute(model, "MIPGap", gap_limit)
    
    n, K, B = data.n, data.K, data.B
    E = data.edges
    
    @variable(model, x[1:n, 1:K], Bin)
    @variable(model, y[e in E], Bin)
    
    @variable(model, λ >= 0)
    @variable(model, μ[e in E] >= 0)
    @variable(model, α[1:K] >= 0)
    @variable(model, β[1:n, 1:K] >= 0)
    
    @objective(model, Min, 
        sum(data.l[e] * y[e] for e in E) +
        data.L * λ +
        sum(3.0 * μ[e] for e in E)
    )
    
    @constraint(model, [i=1:n], sum(x[i,k] for k in 1:K) == 1)
    @constraint(model, [e in E, k in 1:K], y[e] >= x[e[1], k] + x[e[2], k] - 1)
    
    @constraint(model, [e in E], λ + μ[e] >= (data.l_hat[e[1]] + data.l_hat[e[2]]) * y[e])
    @constraint(model, [k=1:K],
        sum(data.w[i] * x[i,k] for i in 1:n) +
        data.W * α[k] +
        sum(data.W_v[i] * β[i,k] for i in 1:n)
        <= B
    )
    @constraint(model, [i=1:n, k=1:K], α[k] + β[i,k] >= data.w[i] * x[i,k])
    
    add_symmetry_breaking_constraints!(model, data)
    
    if warm_start_model !== nothing
        set_warm_start!(model, data, warm_start_model)
    end
    
    optimize!(model)
    
    if verbose
        print_solution(model, data, "Dualisation")
    end
    
    return model
end

# ============================================================================
# MÉTHODE 2 : Résolution Robuste par PLANS COUPANTS (Itératif)
# ============================================================================

function solve_cutting_planes(data::Instance; 
                              max_iter::Int=150, 
                              time_limit::Int=300,
                              gap_limit::Float64=0.01,
                              tol::Float64=1e-6,
                              warm_start_model=nothing,
                              use_heuristic::Bool=true,
                              verbose::Bool=false)
    if verbose
        println("\n" * "="^80)
        println(" " ^ 25 * "MÉTHODE 2 : PLANS COUPANTS (ITÉRATIF)")
        println("="^80)
        if use_heuristic
            println("  ✓ Heuristiques activées pour les sous-problèmes")
        end
    end
    
    n, K, B = data.n, data.K, data.B
    E = data.edges
    
    GRB_ENV = Gurobi.Env()
    model = Model(() -> Gurobi.Optimizer(GRB_ENV))
    set_optimizer_attribute(model, "OutputFlag", verbose ? 1 : 0)

    set_optimizer_attribute(model, "TimeLimit", time_limit)
    set_optimizer_attribute(model, "MIPGap", gap_limit)
    
    @variable(model, x[1:n, 1:K], Bin)
    @variable(model, y[e in E], Bin)
    @variable(model, z >= 0)
    
    @objective(model, Min, z)
    
    @constraint(model, [i=1:n], sum(x[i,k] for k in 1:K) == 1)
    @constraint(model, [e in E, k in 1:K], y[e] >= x[e[1], k] + x[e[2], k] - 1)
    @constraint(model, [k=1:K], sum(data.w[i] * x[i,k] for i in 1:n) <= B)
    
    @constraint(model, z >= sum(data.l[e] * y[e] for e in E))
    
    add_symmetry_breaking_constraints!(model, data)
    
    if warm_start_model !== nothing
        set_warm_start!(model, data, warm_start_model)
    end
    
    cuts_obj = 0
    cuts_feas = 0
    iteration = 0
    start_time = time()
    
    while iteration < max_iter
        iteration += 1
        
        if time() - start_time > time_limit
            if verbose
                println("  ⏱️  Temps limite atteint à l'itération $iteration")
            end
            break
        end
        
        optimize!(model)
        
        if termination_status(model) != MOI.OPTIMAL
            if verbose
                println("  ⚠️  Statut non-optimal: $(termination_status(model))")
            end
            break
        end
        
        x_val = value.(x)
        y_val = Dict(e => value(y[e]) for e in E)
        z_val = value(z)
        
        cuts_added = false
        
        nominal_cost = sum(data.l[e] * y_val[e] for e in E)
        worst_deviation, δ_obj = separation_objective(data, y_val, use_heuristic=use_heuristic)
        
        if nominal_cost + worst_deviation > z_val + tol
            @constraint(model, 
                z >= sum(data.l[e] * y[e] for e in E) +
                     sum((data.l_hat[e[1]] + data.l_hat[e[2]]) * y[e] * δ_obj[e] for e in E)
            )
            cuts_added = true
            cuts_obj += 1
            
            if verbose && iteration % 10 == 0
                println("  ➕ Itér $iteration: Coupe objectif ajoutée (violation: $(round(nominal_cost + worst_deviation - z_val, digits=4)))")
            end
        end
        
        for k in 1:K
            worst_weight, δ_feas = separation_feasibility(data, x_val, k, use_heuristic=use_heuristic)
            
            if worst_weight > B + tol
                @constraint(model,
                    sum(data.w[i] * x[i,k] * (1 + δ_feas[i]) for i in 1:n) <= B
                )
                cuts_added = true
                cuts_feas += 1
                
                if verbose && iteration % 10 == 0
                    println("  ➕ Itér $iteration: Coupe faisabilité P$k ajoutée (violation: $(round(worst_weight - B, digits=4)))")
                end
            end
        end
        
        if !cuts_added
            if verbose
                println("  ✅ Convergence atteinte à l'itération $iteration (aucune coupe à ajouter)")
            end
            break
        end
    end
    
    optimize!(model)
    
    if verbose
        println("\n  📊 Statistiques Plans Coupants:")
        println("     - Itérations: $iteration")
        println("     - Coupes objectif: $cuts_obj")
        println("     - Coupes faisabilité: $cuts_feas")
        println("     - Total coupes: $(cuts_obj + cuts_feas)")
        
        print_solution(model, data, "Plans Coupants")
    end
    
    return model
end

# ============================================================================
# MÉTHODE 3 : Résolution Robuste par BRANCH-AND-CUT (Callbacks Lazy)
# ============================================================================

function solve_branch_and_cut(data::Instance; 
                              time_limit::Int=300,
                              gap_limit::Float64=0.01,
                              warm_start_model=nothing,
                              use_heuristic::Bool=true,
                              verbose::Bool=false)
    if verbose
        println("\n" * "="^80)
        println(" " ^ 25 * "MÉTHODE 3 : BRANCH-AND-CUT (OPTIMISÉ)")
        println(" " ^ 20 * "(Lazy Constraints + User Cuts)" )
        println("="^80)
    end
    
    n, K, B = data.n, data.K, data.B
    E = data.edges
    
    GRB_ENV = Gurobi.Env()
    model = Model(() -> Gurobi.Optimizer(GRB_ENV))
    
    # --- CONFIGURATION GUROBI CRUCIALE ---
    set_optimizer_attribute(model, "OutputFlag", verbose ? 1 : 0)
    set_optimizer_attribute(model, "TimeLimit", time_limit)
    set_optimizer_attribute(model, "MIPGap", gap_limit)
    
    # ACTIVATION DU PRECRUSH : Indispensable pour que les User Cuts fonctionnent
    set_optimizer_attribute(model, "PreCrush", 1) 
    # LazyConstraints : Indispensable pour la validité
    set_optimizer_attribute(model, "LazyConstraints", 1)
    
    @variable(model, x[1:n, 1:K], Bin)
    @variable(model, y[e in E], Bin)
    @variable(model, z >= 0)
    
    @objective(model, Min, z)
    
    # Contraintes statiques de base (Squelette du problème)
    @constraint(model, [i=1:n], sum(x[i,k] for k in 1:K) == 1)
    @constraint(model, [e in E, k in 1:K], y[e] >= x[e[1], k] + x[e[2], k] - 1)
    
    # Borne inférieure "faible" mais utile pour guider le solveur au début
    @constraint(model, z >= sum(data.l[e] * y[e] for e in E))
    
    # Capacité statique (condition nécessaire mais pas suffisante)
    @constraint(model, [k=1:K], sum(data.w[i] * x[i,k] for i in 1:n) <= B)
    
    add_symmetry_breaking_constraints!(model, data)
    
    # --- GESTION INTELLIGENTE DU WARM START ---
    if warm_start_model !== nothing && has_values(warm_start_model)
        try
            x_ref = value.(warm_start_model[:x])
            y_ref = value.(warm_start_model[:y])
            
            # On injecte la solution partielle
            for i in 1:n, k in 1:K
                if x_ref[i, k] > 0.5 set_start_value(x[i, k], 1.0) else set_start_value(x[i, k], 0.0) end
            end
            for e in E
                 if y_ref[e] > 0.5 set_start_value(y[e], 1.0) else set_start_value(y[e], 0.0) end
            end
            
            # ASTUCE : On ne fixe pas z à la valeur statique (qui est fausse en robuste),
            # on laisse Gurobi calculer le z nécessaire ou on met une valeur haute.
            println("  🚀 Warm start (structure x/y) injecté.")
        catch e
            println("  ⚠️ Erreur Warm Start: $e")
        end
    end
    
    cuts_count = [0, 0] # [Objectif, Faisabilité]

    # --- CALLBACK UNIFIÉ ---
    function my_callback_function(cb_data)
        status = callback_node_status(cb_data, model)
        
        # On traite :
        # 1. INTEGER : Solutions entières candidates (Lazy Constraints - OBLIGATOIRE)
        # 2. FRACTIONAL : Solutions en cours de relaxation (User Cuts - PERFORMANCE)
        is_integer = (status == MOI.CALLBACK_NODE_STATUS_INTEGER)
        is_fractional = (status == MOI.CALLBACK_NODE_STATUS_FRACTIONAL)
        
        if !is_integer && !is_fractional
            return
        end
        
        # Récupération des valeurs (entières ou fractionnaires)
        x_val = callback_value.(cb_data, x)
        y_val = Dict(e => callback_value(cb_data, y[e]) for e in E)
        z_val = callback_value(cb_data, z)
        
        # Tolérance : plus stricte pour les entiers, plus lâche pour les fractionnaires (pour éviter de surcharger)
        tol = is_integer ? 1e-6 : 1e-4 
        
        # 1. SÉPARATION DE L'OBJECTIF
        nominal_cost = sum(data.l[e] * y_val[e] for e in E)
        # Optimisation : n'appeler l'heuristique que si z est "proche" du coût nominal
        # sinon on sait déjà qu'on va violer
        
        worst_deviation, δ_obj = separation_objective(data, y_val, use_heuristic=use_heuristic)
        
        robust_obj = nominal_cost + worst_deviation
        
        if robust_obj > z_val + tol
            con = @build_constraint(
                z >= sum(data.l[e] * y[e] for e in E) +
                     sum((data.l_hat[e[1]] + data.l_hat[e[2]]) * y[e] * δ_obj[e] for e in E)
            )
            
            if is_integer
                MOI.submit(model, MOI.LazyConstraint(cb_data), con)
                cuts_count[1] += 1
            else
                MOI.submit(model, MOI.UserCut(cb_data), con)
                # On ne compte pas les User Cuts dans le total final pour ne pas fausser les stats
            end
        end
        
        # 2. SÉPARATION DE LA FAISABILITÉ
        for k in 1:K
            # Petit filtre : si la somme des poids statiques est déjà loin de B, inutile de vérifier le robuste
            # (Optimisation simple)
            current_static_weight = sum(data.w[i] * x_val[i,k] for i in 1:n)
            
            # On sépare seulement si on est potentiellement proche de la limite
            if current_static_weight > B * 0.5 
                worst_weight, δ_feas = separation_feasibility(data, x_val, k, use_heuristic=use_heuristic)
                
                if worst_weight > B + tol
                    con = @build_constraint(
                        sum(data.w[i] * x[i,k] * (1 + δ_feas[i]) for i in 1:n) <= B
                    )
                    
                    if is_integer
                        MOI.submit(model, MOI.LazyConstraint(cb_data), con)
                        cuts_count[2] += 1
                    else
                        MOI.submit(model, MOI.UserCut(cb_data), con)
                    end
                end
            end
        end
    end
    
    # Enregistrement des callbacks
    MOI.set(model, MOI.LazyConstraintCallback(), my_callback_function)
    MOI.set(model, MOI.UserCutCallback(), my_callback_function)
    
    optimize!(model)
    
    if verbose
        println("\n  📊 Statistiques Branch-and-Cut:")
        println("     - Coupes Lazy générées (Entier): $(sum(cuts_count))")
        
        print_solution(model, data, "Branch-and-Cut")
    end
    
    return model
end

# ============================================================================
# MÉTHODE 4 : HEURISTIQUE RAPIDE (NOUVELLE)
# ============================================================================

"""
    solve_heuristic(data::Instance; verbose::Bool=false)

Heuristique constructive rapide pour obtenir une solution initiale.
Utilise une stratégie gloutonne basée sur les poids des nœuds.
"""
function solve_heuristic(data::Instance; verbose::Bool=false)
    if verbose
        println("\n" * "="^80)
        println(" " ^ 25 * "MÉTHODE 4 : HEURISTIQUE RAPIDE (CORRIGÉE)")
        println("="^80)
    end
    
    start_time = time()
    n, K, B = data.n, data.K, data.B
    E = data.edges
    
    # Trier les nœuds par poids décroissant (souvent meilleur pour le Bin Packing que croissant)
    # Vous pouvez garder croissant si vous préférez, mais décroissant remplit mieux les "gros cailloux" d'abord
    nodes_sorted = sort(collect(1:n), by=i -> data.w[i], rev=true)
    
    partitions = [Int[] for _ in 1:K]
    partition_weights = zeros(Float64, K)
    
    # --- CORRECTION 1 : Logique d'affectation robuste ---
    for node in nodes_sorted
        assigned = false
        
        # On cherche toutes les partitions valides (qui ont de la place)
        # On trie ces partitions par poids actuel (pour équilibrer, stratégie "Least Loaded")
        valid_indices = [k for k in 1:K if partition_weights[k] + data.w[node] <= B]
        
        if !isempty(valid_indices)
            # On choisit celle qui est la moins remplie parmi les valides
            sort!(valid_indices, by=k -> partition_weights[k])
            best_k = valid_indices[1]
            
            push!(partitions[best_k], node)
            partition_weights[best_k] += data.w[node]
            assigned = true
        else
            # Cas critique : le nœud ne rentre nulle part (l'heuristique échoue à trouver une solution réalisable)
            if verbose
                println("  ⚠️ Attention: Le nœud $node (poids $(data.w[node])) ne rentre dans aucune partition !")
            end
        end
    end
    
    # Calcul manuel de l'objectif pour affichage
    objective_val = 0.0
    for e in E
        i, j = e
        part_i = findfirst(p -> i in p, partitions)
        part_j = findfirst(p -> j in p, partitions)
        
        # Si un nœud n'est pas assigné, on considère qu'il est isolé (ou on penalise)
        if part_i !== nothing && part_j !== nothing && part_i != part_j
            objective_val += data.l[e]
        end
    end
    
    elapsed_time = time() - start_time
    
    if verbose
        println("\n  📊 Solution Heuristique:")
        for (k, part) in enumerate(partitions)
            if !isempty(part)
                println("     P$k = {$(join(sort(part), ", "))} → poids: $(round(partition_weights[k], digits=2))")
            end
        end
        println("  🎯 Objectif estimé: $(round(objective_val, digits=4))")
        println("  ⏱️  Temps: $(round(elapsed_time, digits=3))s")
    end
    
    # Créer le modèle JuMP final
    GRB_ENV = Gurobi.Env()
    model = Model(() -> Gurobi.Optimizer(GRB_ENV))
    set_optimizer_attribute(model, "OutputFlag", 0) # Silence Gurobi pour l'heuristique
    
    @variable(model, x[1:n, 1:K], Bin)
    @variable(model, y[e in E], Bin)
    
    # Fixer les variables selon la solution heuristique
    for k in 1:K
        for i in 1:n
            if i in partitions[k]
                fix(x[i, k], 1.0, force=true)
            else
                fix(x[i, k], 0.0, force=true)
            end
        end
    end
    
    for e in E
        i, j = e
        part_i = findfirst(p -> i in p, partitions)
        part_j = findfirst(p -> j in p, partitions)
        
        # Gestion correcte des nœuds non assignés (part_i === nothing)
        if part_i !== nothing && part_j !== nothing && part_i != part_j
            fix(y[e], 1.0, force=true)
        else
            fix(y[e], 0.0, force=true)
        end
    end
    
    @objective(model, Min, sum(data.l[e] * y[e] for e in E))
    
    # --- CORRECTION 2 : Appel obligatoire à optimize! ---
    optimize!(model) 
    
    return model
end

# ============================================================================
# FONCTION PRINCIPALE COMPARATIVE 
# ============================================================================


function main_comparative(filepath::String; 
                          time_limit::Int=300,
                          gap_limit::Float64=0.01,
                          use_heuristic::Bool=true,
                          generate_plots::Bool=true) # ← Nouveau paramètre
    
    println("\n" * "╔" * "="^98 * "╗")
    println("║" * " "^30 * "PARTITIONNEMENT ROBUSTE DE GRAPHE" * " "^35 * "║")
    println("║" * " "^28 * "Comparaison des Méthodes de Résolution" * " "^31 * "║")
    println("╚" * "="^98 * "╝")
    
    println("\n📋 Paramètres:")
    println("   - Fichier: $(basename(filepath))")
    println("   - Limite de temps: $(time_limit)s par méthode")
    println("   - Limite de gap: $(gap_limit * 100)%")
    println("   - Heuristiques activées: $(use_heuristic ? "Oui" : "Non")")
    
    # Lecture de l'instance
    instance = read_instance_file(filepath)
    
    # Dictionnaire pour stocker les résultats: (objectif, temps, gap, statut)
    results = Dict{String, Tuple{Float64, Float64, Float64, MOI.TerminationStatusCode}}()
    
    # -------------------------------------------------------------------------
    # 1. STATIQUE (Baseline)
    # -------------------------------------------------------------------------
    println("\n" * "─"^100)
    println("│  [1/5] Résolution STATIQUE (baseline)...")
    println("─"^100)
    
    t_start = time()
    model_static = solve_static(instance, time_limit=time_limit, gap_limit=gap_limit, verbose=true)
    t_static = time() - t_start
    
    obj_static = has_values(model_static) ? objective_value(model_static) : Inf
    gap_static = try MOI.get(model_static, MOI.RelativeGap()) catch; Inf end
    status_static = termination_status(model_static)
    
    results["Statique"] = (obj_static, t_static, gap_static, status_static)

    # -------------------------------------------------------------------------
    # 2. HEURISTIQUE (Méthode 4)
    # -------------------------------------------------------------------------
    println("\n" * "─"^100)
    println("│  [2/5] Résolution HEURISTIQUE...")
    println("─"^100)
    
    t_start = time()
    model_heur = solve_heuristic(instance, verbose=true)
    t_heur = time() - t_start
    
    obj_heur = has_values(model_heur) ? objective_value(model_heur) : Inf
    gap_heur = Inf # Pas de gap prouvé pour une heuristique pure
    status_heur = termination_status(model_heur)
    
    results["Heuristique"] = (obj_heur, t_heur, gap_heur, status_heur)
    
    # -------------------------------------------------------------------------
    # 3. DUALISATION (Méthode 1)
    # -------------------------------------------------------------------------
    println("\n" * "─"^100)
    println("│  [3/5] Résolution par DUALISATION...")
    println("─"^100)
    
    t_start = time()
    model_dual = solve_robust_dualization(instance,
                                          time_limit=time_limit,
                                          gap_limit=gap_limit,
                                          warm_start_model=model_static,
                                          verbose=true)
    t_dual = time() - t_start
    
    obj_dual = has_values(model_dual) ? objective_value(model_dual) : Inf
    gap_dual = try MOI.get(model_dual, MOI.RelativeGap()) catch; Inf end
    status_dual = termination_status(model_dual)
    
    results["Dualisation"] = (obj_dual, t_dual, gap_dual, status_dual)
    
    # -------------------------------------------------------------------------
    # 4. PLANS COUPANTS (Méthode 2)
    # -------------------------------------------------------------------------
    println("\n" * "─"^100)
    println("│  [4/5] Résolution par PLANS COUPANTS...")
    println("─"^100)
    
    t_start = time()
    model_cp = solve_cutting_planes(instance,
                                    time_limit=time_limit,
                                    gap_limit=gap_limit,
                                    warm_start_model=model_static,
                                    use_heuristic=use_heuristic,
                                    verbose=true)
    t_cp = time() - t_start
    
    obj_cp = has_values(model_cp) ? objective_value(model_cp) : Inf
    gap_cp = try MOI.get(model_cp, MOI.RelativeGap()) catch; Inf end
    status_cp = termination_status(model_cp)
    
    results["Plans Coupants"] = (obj_cp, t_cp, gap_cp, status_cp)
    
    # -------------------------------------------------------------------------
    # 5. BRANCH-AND-CUT (Méthode 3)
    # -------------------------------------------------------------------------
    println("\n" * "─"^100)
    println("│  [5/5] Résolution par BRANCH-AND-CUT...")
    println("─"^100)
    
    t_start = time()
    model_bc = solve_branch_and_cut(instance,
                                    time_limit=time_limit,
                                    gap_limit=gap_limit,
                                    warm_start_model=model_static,
                                    use_heuristic=use_heuristic,
                                    verbose=true)
    t_bc = time() - t_start
    
    obj_bc = has_values(model_bc) ? objective_value(model_bc) : Inf
    gap_bc = try MOI.get(model_bc, MOI.RelativeGap()) catch; Inf end
    status_bc = termination_status(model_bc)
    
    results["Branch-and-Cut"] = (obj_bc, t_bc, gap_bc, status_bc)
    
    # -------------------------------------------------------------------------
    # SYNTHÈSE
    # -------------------------------------------------------------------------
    print_comparison_table(results)
    
    # Génération des graphiques
    if generate_plots
        try
            println("\n📊 Génération des graphiques...")
            base_name = splitext(basename(filepath))[1]
            
            # Profil de performance simplifié (Temps)
            plot_performance_profile_single(results, "perf_$(base_name).png")
            
            # Comparaison Barres (Temps vs Objectif)
            plot_comparative_bar_chart(results, "bars_$(base_name).png")
        catch e
            println("⚠️ Erreur lors de la génération des graphiques: $e")
        end
    end
    
    # Recommandations
    println("\n💡 Analyse:")
    robust_methods = ["Dualisation", "Plans Coupants", "Branch-and-Cut"]
    valid_robust = [m for m in robust_methods if results[m][1] < Inf]
    
    if !isempty(valid_robust)
        best_obj = minimum([results[m][1] for m in valid_robust])
        fastest_time = minimum([results[m][2] for m in valid_robust])
        
        for m in valid_robust
            obj, t, _, _ = results[m]
            if obj <= best_obj * 1.0001 && t <= fastest_time * 1.1
                println("   🏆 $m semble être la meilleure méthode ici (Rapide & Optimale).")
            elseif obj <= best_obj * 1.0001
                println("   ⭐ $m a trouvé la solution optimale.")
            end
        end
    end

    return results
end


# ============================================================================
# BENCHMARK SUR PLUSIEURS INSTANCES
# ============================================================================

"""
    benchmark_multiple_instances(instance_files; time_limit=300, gap_limit=0.01)

Teste toutes les méthodes sur plusieurs instances et génère un diagramme de performances.

# Arguments
- `instance_files`: Vecteur de chemins vers les fichiers d'instances
- `time_limit`: Limite de temps par instance et par méthode
- `gap_limit`: Gap d'optimalité toléré
- `use_heuristic`: Utiliser les heuristiques pour sous-problèmes
- `output_dir`: Dossier pour sauvegarder les résultats

# Returns
- Dict avec les résultats de toutes les méthodes sur toutes les instances
"""
function get_solution_string(model, data)
    if !has_values(model)
        return "Pas de solution"
    end
    try
        x_val = value.(model[:x])
        partitions_str = ""
        for k in 1:data.K
            group = [i for i in 1:data.n if x_val[i,k] > 0.5]
            if !isempty(group)
                partitions_str *= "P$k={$(join(group, ","))} "
            end
        end
        return isempty(partitions_str) ? "Aucune partition" : strip(partitions_str)
    catch e
        return "Erreur lecture: $e"
    end
end

# --- FONCTION PRINCIPALE BLINDÉE ---
function benchmark_multiple_instances(instance_files::Vector{String};
                                     time_limit::Int=300,
                                     gap_limit::Float64=0.01,
                                     use_heuristic::Bool=true,
                                     output_dir::String="results")
    
    println("\n" * "╔" * "="^98 * "╗")
    println("║" * " "^20 * "BENCHMARK SÉCURISÉ (CSV + EXCEL)" * " "^44 * "║")
    println("╚" * "="^98 * "╝")
    
    mkpath(output_dir)
    
    # 1. CRÉATION DU FICHIER DE SAUVEGARDE CSV (Le filet de sécurité)
    csv_filename = joinpath(output_dir, "backup_live_data.csv")
    println("  💾 Fichier de sauvegarde temps réel : $csv_filename")
    
    # On initialise le fichier CSV avec les en-têtes (si le fichier n'existe pas)
    # On utilise ';' comme séparateur pour éviter les problèmes avec les virgules des partitions
    if !isfile(csv_filename)
        open(csv_filename, "w") do file
            println(file, "Instance;Methode;Statut;Temps_s;Objectif;Gap_pct;Details_Solution")
        end
    end

    # Préparation des conteneurs pour l'Excel final
    excel_instances = String[]
    excel_methods = String[]
    excel_status = String[]
    excel_time = Float64[]
    excel_objective = Any[]
    excel_gap = Any[]
    excel_solution = String[]
    
    # Structure pour le graphique
    all_results = Dict{String, Vector{Tuple{Float64, MOI.TerminationStatusCode}}}()
    method_names = ["Statique", "Dualisation", "Plans Coupants", "Branch-and-Cut", "Heuristique"]
    for m in method_names; all_results[m] = []; end
    
    # --- BOUCLE PRINCIPALE ---
    for (inst_idx, filepath) in enumerate(instance_files)
        inst_name = basename(filepath)
        println("\n" * "─"^80)
        println("  Instance $inst_idx/$(length(instance_files)): $inst_name")
        println("─"^80)
        
        try
            instance = read_instance_file(filepath)
            
            methods_to_test = [
                ("Statique", (inst) -> solve_static(inst, time_limit=time_limit, gap_limit=gap_limit)),
                ("Heuristique", (inst) -> solve_heuristic(inst)),
                ("Dualisation", (inst) -> solve_robust_dualization(inst, time_limit=time_limit, gap_limit=gap_limit)),
                ("Plans Coupants", (inst) -> solve_cutting_planes(inst, time_limit=time_limit, gap_limit=gap_limit, use_heuristic=use_heuristic)),
                ("Branch-and-Cut", (inst) -> solve_branch_and_cut(inst, time_limit=time_limit, gap_limit=gap_limit, use_heuristic=use_heuristic))
            ]
            
            for (method_name, solver_func) in methods_to_test
                print("  ⏳ $method_name... ")
                flush(stdout)
                
                t_start = time()
                
                # Valeurs par défaut
                final_status = "ERROR_INIT"
                final_time = 0.0
                final_obj = "N/A"
                final_gap = "-"
                final_sol = ""
                status_code = MOI.OTHER_ERROR
                
                try
                    model = solver_func(instance)
                    final_time = time() - t_start
                    status_code = termination_status(model)
                    final_status = string(status_code)
                    
                    if has_values(model)
                        val_obj = objective_value(model)
                        final_obj = round(val_obj, digits=4)
                        final_sol = get_solution_string(model, instance)
                        
                        try
                            gap_val = MOI.get(model, MOI.RelativeGap())
                            final_gap = (gap_val < Inf) ? round(gap_val * 100, digits=2) : "Inf"
                        catch
                            final_gap = "-"
                        end
                    else
                        final_sol = "Pas de solution"
                    end
                    
                    print("✓ $(round(final_time, digits=2))s ")
                    if typeof(final_obj) <: Number
                        println("| Obj: $final_obj")
                    else
                        println("| $final_status")
                    end
                    
                catch e
                    println("\n  ✗ Erreur exécution: $e")
                    final_status = "CRASH_CODE"
                    final_time = time() - t_start
                    final_sol = "Erreur: $(replace(string(e), "\n" => " "))" # Retire les sauts de ligne pour le CSV
                end
                
                # Ajout aux résultats pour le graphique
                push!(all_results[method_name], (final_time, status_code))
                
                # --- SAUVEGARDE IMMÉDIATE DANS LE CSV (Le plus important) ---
                try
                    open(csv_filename, "a") do file
                        # On remplace les ; par des , dans la solution pour ne pas casser le CSV
                        clean_sol = replace(final_sol, ";" => ",")
                        # Ecriture : Instance;Methode;Statut;Temps;Obj;Gap;Sol
                        println(file, "$inst_name;$method_name;$final_status;$final_time;$final_obj;$final_gap;$clean_sol")
                    end
                catch e_csv
                    println("  ⚠️ Echec écriture CSV: $e_csv")
                end
                
                # Stockage en mémoire pour Excel
                push!(excel_instances, inst_name)
                push!(excel_methods, method_name)
                push!(excel_status, final_status)
                push!(excel_time, final_time)
                push!(excel_objective, final_obj)
                push!(excel_gap, final_gap)
                push!(excel_solution, final_sol)
            end
            
        catch e
            println("  ⚠️  Erreur chargement instance: $e")
        end
    end
    
    # --- GÉNÉRATION EXCEL FINALE (Avec correction Char -> String) ---
    excel_filename = joinpath(output_dir, "benchmark_final.xlsx")
    println("\n" * "="^80)
    println("  💾 Génération de l'Excel final : $excel_filename")
    
    try
        # Astuce : string.() force la conversion de tout (Char, Int, SubString) en String pure
        XLSX.writetable(excel_filename, 
            instances = string.(excel_instances),
            methodes = string.(excel_methods),
            statut = string.(excel_status),
            temps_s = excel_time,
            objectif = string.(excel_objective), # Convertit aussi les "N/A" et nombres en string pour uniformiser
            gap_pct = string.(excel_gap),        # Evite l'erreur sur les '-' (Char)
            details_solution = string.(excel_solution),
            overwrite = true
        )
        println("  ✅ Excel créé avec succès !")
    catch e
        println("  ❌ Erreur création Excel: $e")
        println("  👉 PAS DE PANIQUE : Toutes vos données sont dans 'backup_live_data.csv'")
    end

    # Graphiques
    try
        plot_performance_profile(all_results, joinpath(output_dir, "performance_profiles.png"))
        println("  ✅ Graphiques générés.")
    catch e_plot
        println("  ⚠️ Erreur graphiques: $e_plot")
    end
    
    println("\n✅ Terminé. Vérifiez le dossier '$output_dir'.")
    return all_results
end

# ============================================================================
# EXÉCUTION
# ============================================================================
# Exemple 1: Une seule instance

results = main_comparative(
    "data/data/10_ulysses_3.tsp",
    time_limit=200,        
    gap_limit=0.09,
    use_heuristic=true,
    generate_plots=false
)
"""
# Exemple 2: Benchmark sur plusieurs instances (décommenter pour utiliser)
instance_files = [
    "data/data/44_lin_3.tsp",
    "data/data/48_att_3.tsp",
    "data/data/52_berlin_3.tsp",
    "data/data/70_st_3.tsp",
    "data/data/80_gr_3.tsp",
    "data/data/100_kroA_3.tsp",
    "data/data/202_gr_3.tsp",
    "data/data/318_lin_3.tsp",
    "data/data/400_rd_3.tsp",
    "data/data/532_att_3.tsp",
]
 
 all_results = benchmark_multiple_instances(
     instance_files,
     time_limit=100,
     gap_limit=0.05,
     use_heuristic=true,
     output_dir="benchmark_results"
 )

"""
 """
 "data/data/10_ulysses_6.tsp",
    "data/data/14_burma_6.tsp",
    "data/data/22_ulysses_6.tsp",
    "data/data/26_eil_6.tsp",
    "data/data/30_eil_6.tsp",
    "data/data/34_pr_6.tsp",
    "data/data/38_rat_6.tsp",
    "data/data/40_eil_3.tsp",
 
    "data/data/40_eil_6.tsp",
"""