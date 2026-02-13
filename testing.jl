using JuMP
using Gurobi
using Random
using LinearAlgebra
using Statistics
using Printf
using Plots
using Pkg
using XLSX
using JuMP
using Dates
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
    println(" Lecture du fichier : $filepath")
    
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
    # 1. Calculer le temps total MAX parmi toutes les méthodes pour dimensionner l'axe X
    max_total_time = 0.0
    
    for method in keys(all_results)
        # On ne garde que les temps des succès pour le cumul
        valid_times = [r[1] for r in all_results[method] if r[2] == MOI.OPTIMAL || r[2] == MOI.TIME_LIMIT]
        # On suppose qu'on les résout du plus rapide au plus lent
        sort!(valid_times)
        if !isempty(valid_times)
            total_time = sum(valid_times)
            if total_time > max_total_time
                max_total_time = total_time
            end
        end
    end
    
    limit_x = max_total_time * 1.05 # +5% de marge

    # Créer le graphique
    p = plot(
        xlabel="Temps Cumulé (s)", # Changement de label
        ylabel="Nombre d'instances résolues",
        title="Efficacité Globale (Temps Cumulé)",
        legend=:bottomright,
        size=(900, 600),
        grid=true,
        gridstyle=:dash,
        gridalpha=0.3,
        xlims=(0, limit_x)
    )
    
    colors = [:blue, :green, :orange, :purple, :red, :brown]
    method_names = collect(keys(all_results))
    
    for (idx, method) in enumerate(method_names)
        results = all_results[method]
        
        # 2. FILTRER : On ne garde que les succès
        valid_results = filter(r -> r[2] == MOI.OPTIMAL || r[2] == MOI.TIME_LIMIT, results)
        
        # 3. TRIER par temps d'exécution croissant (Stratégie : on résout les faciles d'abord)
        sort!(valid_results, by = x -> x[1])
        
        # 4. CONSTRUIRE LA COURBE CUMULATIVE
        xs = Float64[0.0]
        ys = Int[0]
        
        current_cumul = 0.0
        
        for (i, (t, status)) in enumerate(valid_results)
            # On ajoute le temps de l'instance courante au total
            new_cumul = current_cumul + t
            
            
            push!(xs, new_cumul) # Point en bas de la marche (temps atteint, pas encore compté)
            push!(ys, i-1)
            
            push!(xs, new_cumul) # Point en haut de la marche (temps atteint, instance comptée)
            push!(ys, i)
            
            current_cumul = new_cumul
        end
        
        # Prolonge la courbe jusqu'à la fin du graphique (plateau final)
        if !isempty(xs)
            push!(xs, limit_x)
            push!(ys, ys[end])
        end
        
        plot!(p, xs, ys,
              label=method,
              linewidth=2.5,
              color=colors[mod1(idx, length(colors))],
              linestyle=:solid)
    end
    
    savefig(p, output_file)
    println("  Graphique de temps cumulé sauvegardé: $output_file")
    
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
    println("   Diagramme comparatif sauvegardé: $output_file")
    
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
        println("   Partitions:")
        for (k, group) in enumerate(partitions)
            weight = sum(data.w[i] for i in group)
            println("     P$k = {$(join(group, ", "))} → poids: $(round(weight, digits=2))")
        end
    end
    
    obj_val = objective_value(model)
    println("   Objectif: $(round(obj_val, digits=4))")
    
    try
        gap = MOI.get(model, MOI.RelativeGap())
        if gap < Inf
            println("   Gap: $(round(gap * 100, digits=2))%")
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
                println("\n Convergence parfaite des méthodes robustes (écart < 0.0001)")
            elseif diff < 1.0
                println("\n✓ Bonne convergence des méthodes robustes (écart: $(round(diff, digits=4)))")
            else
                println("\n  Écart significatif entre les méthodes robustes: $(round(diff, digits=2))")
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
    
    println("   Contraintes de brisure de symétrie ajoutées")
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
        
        println("   Solution initiale fournie (warm start activé)")
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
# MÉTHODE 1 : Résolution Robuste par DUALISATION 
# ============================================================================

function solve_robust_dualization(data::Instance; 
                                 time_limit::Int=300, 
                                 gap_limit::Float64=0.01,
                                 warm_start_model=nothing,
                                 verbose::Bool=false)
    if verbose
        println("\n" * "="^80)
        println(" " ^ 25 * "MÉTHODE 1 : DUALISATION (OPTIMISÉE)")
        println(" " ^ 20 * "(Relaxation y + Presolve Agressif)")
        println("="^80)
    end

    GRB_ENV = Gurobi.Env()
    model = Model(() -> Gurobi.Optimizer(GRB_ENV))
    
    # --- OPTIMISATION 1 : Paramètres Gurobi pour la performance ---
    set_optimizer_attribute(model, "OutputFlag", verbose ? 1 : 0)
    set_optimizer_attribute(model, "TimeLimit", time_limit)
    set_optimizer_attribute(model, "MIPGap", gap_limit)
    
    set_optimizer_attribute(model, "Presolve", 2) 
    set_optimizer_attribute(model, "Cuts", 2) 
    set_optimizer_attribute(model, "Symmetry", 2)
    set_optimizer_attribute(model, "Method", 3)

    n, K, B = data.n, data.K, data.B
    E = data.edges
    
    # --- VARIABLES ---
    @variable(model, x[1:n, 1:K], Bin)
    
    # --- OPTIMISATION 2 : Relaxation de y (Variable Continue au lieu de Binaire) ---

    @variable(model, 0 <= y[e in E] <= 1) 
    
    @variable(model, λ >= 0)
    @variable(model, μ[e in E] >= 0)
    @variable(model, α[1:K] >= 0)
    @variable(model, β[1:n, 1:K] >= 0)
    
    # --- OBJECTIF ROBUSTE ---
    # Min (Coût nominal + Incertitude Distances)
    @objective(model, Min, 
        sum(data.l[e] * y[e] for e in E) +
        data.L * λ +
        sum(3.0 * μ[e] for e in E)
    )
    
    # --- CONTRAINTES ---
    
    # 1. Partitionnement : chaque nœud dans exactement un groupe
    @constraint(model, [i=1:n], sum(x[i,k] for k in 1:K) == 1)
    
    # 2. Lien x-y (Linéarisation)
    # Si i et j sont dans k, alors y_e doit être 1.
    @constraint(model, [e in E, k in 1:K], y[e] >= x[e[1], k] + x[e[2], k] - 1)
    
    # 3. Contrainte Duale Distances (Incertitude Objectif)
    @constraint(model, [e in E], λ + μ[e] >= (data.l_hat[e[1]] + data.l_hat[e[2]]) * y[e])
    
    # 4. Contrainte Duale Poids (Capacité Robuste)
    @constraint(model, [k=1:K],
        sum(data.w[i] * x[i,k] for i in 1:n) +    # Poids nominal
        data.W * α[k] +                           # Budget global incertitude poids
        sum(data.W_v[i] * β[i,k] for i in 1:n)    # Budget local
        <= B
    )
    
    # 5. Lien Dualité Poids
    @constraint(model, [i=1:n, k=1:K], α[k] + β[i,k] >= data.w[i] * x[i,k])
    
    # --- OPTIMISATION 3 : Symétrie minimale ---

    @constraint(model, x[1, 1] == 1)
    
    # Warm Start
    if warm_start_model !== nothing && has_values(warm_start_model)
        try
            x_ref = value.(warm_start_model[:x])
            # On ne passe que les variables entières x pour le warm start
            for i in 1:n, k in 1:K
                if x_ref[i, k] > 0.5 set_start_value(x[i, k], 1.0) else set_start_value(x[i, k], 0.0) end
            end
            if verbose; println("  🚀 Warm start injecté."); end
        catch
        end
    end
    
    optimize!(model)
    
    if verbose
        print_solution(model, data, "Dualisation (Optimisée)")
    end
    
    return model
end

# ============================================================================
# MÉTHODE 2 : Résolution Robuste par PLANS COUPANTS (Itératif)
# ============================================================================

function solve_cutting_planes(data::Instance; 
                              max_iter::Int=200, 
                              time_limit::Int=300,
                              gap_limit::Float64=0.01,
                              tol::Float64=1e-6,
                              warm_start_model=nothing,
                              use_heuristic::Bool=true,
                              verbose::Bool=false)
    if verbose
        println("\n" * "="^80)
        println(" " ^ 25 * "MÉTHODE 2 : PLANS COUPANTS (TIMEOUT SECURE)")
        println("="^80)
    end
    
    n, K, B = data.n, data.K, data.B
    E = data.edges
    
    GRB_ENV = Gurobi.Env()
    model = Model(() -> Gurobi.Optimizer(GRB_ENV))
    
    set_optimizer_attribute(model, "OutputFlag", verbose ? 1 : 0)
    set_optimizer_attribute(model, "MIPGap", gap_limit)
    
    @variable(model, x[1:n, 1:K], Bin)
    @variable(model, 0 <= y[e in E] <= 1) 
    @variable(model, z >= 0)
    
    @objective(model, Min, z)
    
    @constraint(model, [i=1:n], sum(x[i,k] for k in 1:K) == 1)
    @constraint(model, [e in E, k in 1:K], y[e] >= x[e[1], k] + x[e[2], k] - 1)
    @constraint(model, [k=1:K], sum(data.w[i] * x[i,k] for i in 1:n) <= B)
    @constraint(model, z >= sum(data.l[e] * y[e] for e in E))
    
    add_symmetry_breaking_constraints!(model, data)
    
    if warm_start_model !== nothing && has_values(warm_start_model)
        try
            x_ref = value.(warm_start_model[:x])
            for i in 1:n, k in 1:K
                if x_ref[i, k] > 0.5 set_start_value(x[i, k], 1.0) else set_start_value(x[i, k], 0.0) end
            end
        catch; end
    end
    
    cuts_obj = 0
    cuts_feas = 0
    iteration = 0
    start_time = time()
    
    while iteration < max_iter
        iteration += 1
        elapsed = time() - start_time
        remaining = time_limit - elapsed
        
        if remaining <= 0.5
            if verbose; println("  ⏱️  Temps limite global atteint."); end
            break
        end
        
        set_optimizer_attribute(model, "TimeLimit", remaining)
        optimize!(model)
        
        status = termination_status(model)
        
        if status == MOI.TIME_LIMIT
            if verbose; println("  ⏱️  Timeout Gurobi atteint."); end
            break 
        end
        
        if status != MOI.OPTIMAL
            break
        end
        
        if !has_values(model)
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
        end
        
        for k in 1:K
            worst_weight, δ_feas = separation_feasibility(data, x_val, k, use_heuristic=use_heuristic)
            
            if worst_weight > B + tol
                @constraint(model,
                    sum(data.w[i] * x[i,k] * (1 + δ_feas[i]) for i in 1:n) <= B
                )
                cuts_added = true
                cuts_feas += 1
            end
        end
        
        if !cuts_added
            if verbose; println("  ✅ Convergence atteinte à l'itération $iteration"); end
            break
        end
    end
    
    # --- VÉRIFICATION FINALE DE LA ROBUSTESSE (POST-OPTIMIZATION) ---
    if has_values(model)
        x_val = value.(x)
        y_val = Dict(e => value(y[e]) for e in E)
        z_val_model = value(z)
        
        # 1. Vérification Stricte de la Faisabilité (Robustesse Poids)
        is_robust_feasible = true
        max_violation = 0.0
        
        for k in 1:K
            # On utilise le check exact ici pour être sûr
            worst_weight, _ = separation_feasibility(data, x_val, k, use_heuristic=false)
            if worst_weight > B + 1e-5
                is_robust_feasible = false
                max_violation = max(max_violation, worst_weight - B)
            end
        end
        
        # 2. Calcul du Vrai Coût Robuste
        nominal_cost = sum(data.l[e] * y_val[e] for e in E)
        worst_dev, _ = separation_objective(data, y_val, use_heuristic=false)
        true_robust_obj = nominal_cost + worst_dev
        
        if verbose
            println("\n  🔍 VÉRIFICATION FINALE DE LA SOLUTION :")
            if !is_robust_feasible
                println("      SOLUTION NON RÉALISABLE (Violation incertitude poids : +$(round(max_violation, digits=3)))")
                println("       La solution est rejetée car elle ne résiste pas au pire cas.")
            else
                println("      Solution Robustement Réalisable")
                println("     Objectif Modèle (Borne Inf) : $(round(z_val_model, digits=4))")
                println("      Vrai Coût Robuste (Calculé) : $(round(true_robust_obj, digits=4))")
                
                if z_val_model < true_robust_obj - 1e-4
                    println("       Attention : Le modèle sous-estime le coût réel (écart dû au Timeout)")
                end
            end
            
            if is_robust_feasible
                 print_solution(model, data, "Plans Coupants (Vérifié)")
            end
        end
        
       
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
                              use_heuristic::Bool=true, # Essayez false si le problème persiste
                              verbose::Bool=false)
    if verbose
        println("\n" * "="^80)
        println(" " ^ 25 * "MÉTHODE 3 : BRANCH-AND-CUT (CORRIGÉ)")
        println("="^80)
    end
    
    n, K, B = data.n, data.K, data.B
    E = data.edges
    
    GRB_ENV = Gurobi.Env()
    model = Model(() -> Gurobi.Optimizer(GRB_ENV))
    
    set_optimizer_attribute(model, "OutputFlag", verbose ? 1 : 0)
    set_optimizer_attribute(model, "TimeLimit", time_limit)
    set_optimizer_attribute(model, "MIPGap", gap_limit)
    set_optimizer_attribute(model, "PreCrush", 1) 
    set_optimizer_attribute(model, "LazyConstraints", 1)
    
    @variable(model, x[1:n, 1:K], Bin)
    @variable(model, y[e in E], Bin)
    @variable(model, z >= 0)
    
    @objective(model, Min, z)
    
    @constraint(model, [i=1:n], sum(x[i,k] for k in 1:K) == 1)
    @constraint(model, [e in E, k in 1:K], y[e] >= x[e[1], k] + x[e[2], k] - 1)
    @constraint(model, z >= sum(data.l[e] * y[e] for e in E))
    @constraint(model, [k=1:K], sum(data.w[i] * x[i,k] for i in 1:n) <= B)
    
    add_symmetry_breaking_constraints!(model, data)
    
    if warm_start_model !== nothing && has_values(warm_start_model)
        try
            x_ref = value.(warm_start_model[:x])
            y_ref = value.(warm_start_model[:y])
            for i in 1:n, k in 1:K
                if x_ref[i, k] > 0.5 set_start_value(x[i, k], 1.0) else set_start_value(x[i, k], 0.0) end
            end
            for e in E
                 if y_ref[e] > 0.5 set_start_value(y[e], 1.0) else set_start_value(y[e], 0.0) end
            end
        catch; end
    end
    
    cuts_count = [0, 0] # [Lazy, User]

    # --- FONCTION DE SÉPARATION (CORRIGÉE) ---
    function find_violated_cuts(x_val, y_val, z_val, tolerance)
        violated_cuts = [] 
        
        # 1. Objectif (Robustesse des distances)
        nominal_cost = sum(data.l[e] * y_val[e] for e in E)
        worst_deviation, δ_obj = separation_objective(data, y_val, use_heuristic=use_heuristic)
        
        if nominal_cost + worst_deviation > z_val + tolerance
            push!(violated_cuts, (:obj, δ_obj))
        end
        
        # 2. Faisabilité (Robustesse des poids)
        for k in 1:K
            # Calcul du poids nominal actuel de la partition k
            current_weight = sum(data.w[i] * x_val[i,k] for i in 1:n)
            
            if current_weight > 1e-6 
                worst_weight, δ_feas = separation_feasibility(data, x_val, k, use_heuristic=use_heuristic)
                
                if worst_weight > B + tolerance
                    push!(violated_cuts, (:feas, (k, δ_feas)))
                end
            end
        end
        
        return violated_cuts
    end

    # --- CALLBACK LAZY (Validité Entière) ---
    function lazy_cb(cb_data)
        if callback_node_status(cb_data, model) != MOI.CALLBACK_NODE_STATUS_INTEGER
            return
        end
        
        x_val = callback_value.(cb_data, x)
        y_val = Dict(e => callback_value(cb_data, y[e]) for e in E)
        z_val = callback_value(cb_data, z)
        
        # Tolérance stricte
        cuts = find_violated_cuts(x_val, y_val, z_val, 1e-6)
        
        for (type, data_cut) in cuts
            if type == :obj
                δ_obj = data_cut
                con = @build_constraint(
                    z >= sum(data.l[e] * y[e] for e in E) +
                         sum((data.l_hat[e[1]] + data.l_hat[e[2]]) * y[e] * δ_obj[e] for e in E)
                )
                MOI.submit(model, MOI.LazyConstraint(cb_data), con)
                cuts_count[1] += 1
            elseif type == :feas
                (k, δ_feas) = data_cut
                con = @build_constraint(
                    sum(data.w[i] * x[i,k] * (1 + δ_feas[i]) for i in 1:n) <= B
                )
                MOI.submit(model, MOI.LazyConstraint(cb_data), con)
                cuts_count[1] += 1
            end
        end
    end

    # --- CALLBACK USER (Performance Fractionnaire) ---
    function user_cb(cb_data)
        if callback_node_status(cb_data, model) != MOI.CALLBACK_NODE_STATUS_FRACTIONAL
            return
        end
        
        x_val = callback_value.(cb_data, x)
        y_val = Dict(e => callback_value(cb_data, y[e]) for e in E)
        z_val = callback_value(cb_data, z)
        
        cuts = find_violated_cuts(x_val, y_val, z_val, 1e-4)
        
        for (type, data_cut) in cuts
            if type == :obj
                δ_obj = data_cut
                con = @build_constraint(
                    z >= sum(data.l[e] * y[e] for e in E) +
                         sum((data.l_hat[e[1]] + data.l_hat[e[2]]) * y[e] * δ_obj[e] for e in E)
                )
                MOI.submit(model, MOI.UserCut(cb_data), con)
                cuts_count[2] += 1
            elseif type == :feas
                (k, δ_feas) = data_cut
                con = @build_constraint(
                    sum(data.w[i] * x[i,k] * (1 + δ_feas[i]) for i in 1:n) <= B
                )
                MOI.submit(model, MOI.UserCut(cb_data), con)
                cuts_count[2] += 1
            end
        end
    end
    
    MOI.set(model, MOI.LazyConstraintCallback(), lazy_cb)
    MOI.set(model, MOI.UserCutCallback(), user_cb)
    
    optimize!(model)
    
    if verbose
        println("\n  📊 Statistiques Branch-and-Cut:")
        println("     - Lazy Constraints (Validité): $(cuts_count[1])")
        println("     - User Cuts (Performance):     $(cuts_count[2])")
        print_solution(model, data, "Branch-and-Cut")
    end
    
    return model
end

# ============================================================================
# MÉTHODE 4 : HEURISTIQUE RAPIDE
# ============================================================================


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
                          generate_plots::Bool=true)
    
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
    
    # Dictionnaire pour stocker les résultats
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
    gap_heur = Inf 
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
            plot_performance_profile_single(results, "perf_$(base_name).png")
            plot_comparative_bar_chart(results, "bars_$(base_name).png")
        catch e
            println("⚠️ Erreur lors de la génération des graphiques: $e")
        end
    end
    
    # -------------------------------------------------------------------------
    # ANALYSE ET MEILLEURE SOLUTION 
    # -------------------------------------------------------------------------
    println("\n💡 Analyse Rapide:")
    robust_methods = ["Dualisation", "Plans Coupants", "Branch-and-Cut"]
    valid_robust = [m for m in robust_methods if haskey(results, m) && results[m][1] < Inf]
    
    if !isempty(valid_robust)
        # On trie d'abord par objectif (min), puis par temps (min)
        best_method = sort(valid_robust, by = m -> (results[m][1], results[m][2]))[1]
        
        println("\n" * "★"^80)
        println("   🏆 MEILLEURE SOLUTION ROBUSTE TROUVÉE (Gagnant : $best_method)")
        println("★"^80)
        
        # Récupération du modèle correspondant
        best_model = nothing
        if best_method == "Dualisation"
            best_model = model_dual
        elseif best_method == "Plans Coupants"
            best_model = model_cp
        elseif best_method == "Branch-and-Cut"
            best_model = model_bc
        end
        
        # Affichage propre de la solution
        if best_model !== nothing
            print_solution(best_model, instance, best_method)
        else
            println("Erreur technique : Modèle introuvable.")
        end
        println("★"^80 * "\n")
        
    else
        println("⚠️ Aucune méthode robuste n'a trouvé de solution valide.")
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

function benchmark_multiple_instances(instance_files::Vector{String};
                                     time_limit::Int=300,
                                     gap_limit::Float64=0.01,
                                     use_heuristic::Bool=true,
                                     output_dir::String="results")
    
    println("\n" * "╔" * "="^98 * "╗")
    println("║" * " "^20 * "BENCHMARK SÉCURISÉ (CSV + EXCEL)" * " "^44 * "║")
    println("╚" * "="^98 * "╝")
    
    mkpath(output_dir)
    
    csv_filename = joinpath(output_dir, "backup_live_data.csv")
    println("   Fichier de sauvegarde temps réel : $csv_filename")
    
    # On initialise le fichier CSV avec les en-têtes (si le fichier n'existe pas)
    # On utilise ';' comme séparateur pour éviter les problèmes avec les virgules des partitions
    if !isfile(csv_filename)
        open(csv_filename, "w") do file
            println(file, "Instance;Methode;Statut;Temps_s;Objectif;Gap_pct;Details_Solution")
        end
    end

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
                print("   $method_name... ")
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
                    final_sol = "Erreur: $(replace(string(e), "\n" => " "))" 
                end
                
                # Ajout aux résultats pour le graphique
                push!(all_results[method_name], (final_time, status_code))
                
                # --- SAUVEGARDE IMMÉDIATE DANS LE CSV (Le plus important) ---
                try
                    open(csv_filename, "a") do file
                        clean_sol = replace(final_sol, ";" => ",")
                        println(file, "$inst_name;$method_name;$final_status;$final_time;$final_obj;$final_gap;$clean_sol")
                    end
                catch e_csv
                    println("   Echec écriture CSV: $e_csv")
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
            println("    Erreur chargement instance: $e")
        end
    end
    
    # --- GÉNÉRATION EXCEL FINALE (Avec correction Char -> String) ---
    excel_filename = joinpath(output_dir, "benchmark_final.xlsx")
    println("\n" * "="^80)
    println("   Génération de l'Excel final : $excel_filename")
    
    try
        XLSX.writetable(excel_filename, 
            instances = string.(excel_instances),
            methodes = string.(excel_methods),
            statut = string.(excel_status),
            temps_s = excel_time,
            objectif = string.(excel_objective), 
            gap_pct = string.(excel_gap),        
            details_solution = string.(excel_solution),
            overwrite = true
        )
        println("  ✅ Excel créé avec succès !")
    catch e
        println("   données sont crées 'backup_live_data.csv'")
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
# 1. FONCTION DE TRAÇAGE : Courbe d'Efficacité Cumulée
# ============================================================================

"""
    plot_cumulative_solved(results_data, time_budget, output_file="profil_resolution.png")

Trace le nombre d'instances résolues (Axe Y) en fonction du temps cumulé (Axe X).
Chaque méthode a sa propre courbe en escalier.
"""
function plot_cumulative_solved(results_data::Dict, time_budget::Real, output_file::String="profil_resolution.png")
    
    p = plot(
        title  = "Instances Résolues vs Temps Cumulé",
        xlabel = "Temps Global (s)",
        ylabel = "Nombre d'instances résolues",
        legend = :bottomright,
        xlims  = (0, time_budget * 1.05),
        size   = (900, 600),
        grid   = true,
        framestyle = :box
    )

    colors = [:blue, :green, :orange, :purple, :red]
    methods = sort(collect(keys(results_data)))
    
    max_y = 0

    for (idx, method) in enumerate(methods)
        # data est un vecteur de tuples : (Temps_Instance, Est_Resolue)
        # On doit le transformer en temps cumulé pour les succès
        data = results_data[method]
        
        cumulative_time = 0.0
        solved_count = 0
        
        # Points pour le graphique (x, y)
        xs = Float64[0.0]
        ys = Int[0]

        for (t_inst, is_solved) in data
            cumulative_time += t_inst
            
            # Si on dépasse le budget global, on arrête le tracé là
            if cumulative_time > time_budget
                push!(xs, time_budget)
                push!(ys, ys[end])
                break
            end

            # On avance dans le temps (horizontalement)
            push!(xs, cumulative_time)
            push!(ys, solved_count) # On reste au niveau précédent avant de monter

            if is_solved
                solved_count += 1
                # On monte une marche (verticalement)
                push!(xs, cumulative_time)
                push!(ys, solved_count)
            end
        end

        # Prolonger jusqu'à la fin du budget si la méthode a fini toutes les instances avant
        if !isempty(xs) && xs[end] < time_budget
            push!(xs, time_budget)
            push!(ys, ys[end])
        end

        max_y = max(max_y, solved_count)

        plot!(p, xs, ys, 
              label = "$method ($solved_count résolues)", 
              linewidth = 2.5,
              color = colors[mod1(idx, length(colors))],
              linestyle = :solid) # ou :step
    end
    
    # Ajuster l'axe Y pour avoir des entiers
    plot!(p, yticks = 0:max(1, max_y+1))

    savefig(p, output_file)
    println("   📊 Graphique généré : $output_file")
end

# ============================================================================
# 2. FONCTION PRINCIPALE : Benchmark "Budget Global"
# ============================================================================

"""
    benchmark_global_budget(instance_files; global_time_limit=1800, gap_limit=0.01)

Parcourt les MÉTHODES une par une. Pour chaque méthode, on lui donne un budget global.
Elle tente de résoudre les instances à la chaîne.
"""

function benchmark_global_budget(instance_files::Vector{String};
                                 global_time_limit::Int=1800, # ex: 30 minutes TOTALES par méthode
                                 gap_limit::Float64=0.01,
                                 output_dir::String="benchmark_budget")
    
    mkpath(output_dir)
    timestamp = Dates.format(now(), "yyyy-mm-dd_HHMM")
    
    println("\n" * "╔" * "="^90 * "╗")
    println("║" * " "^25 * "BENCHMARK : BUDGET GLOBAL PAR MÉTHODE" * " "^28 * "║")
    println("╚" * "="^90 * "╝")
    println(" ⏱️  Budget par méthode : $(global_time_limit) s ($(round(global_time_limit/60, digits=1)) min)")
    println(" 📂 Instances à traiter : $(length(instance_files))")
    
    # 1. Définition des tâches
    solvers = [
        ("Statique",       (inst, t) -> solve_static(inst, time_limit=t, gap_limit=gap_limit)),
        ("Heuristique",    (inst, t) -> solve_heuristic(inst)), # Heuristique souvent < 1s
        ("Dualisation",    (inst, t) -> solve_robust_dualization(inst, time_limit=t, gap_limit=gap_limit)),
        ("Plans Coupants", (inst, t) -> solve_cutting_planes(inst, time_limit=t, gap_limit=gap_limit, use_heuristic=true)),
        ("Branch-and-Cut", (inst, t) -> solve_branch_and_cut(inst, time_limit=t, gap_limit=gap_limit, use_heuristic=true))
    ]

    # Structures de stockage
    results_for_plot = Dict{String, Vector{Tuple{Float64, Bool}}}()
    
    # Excel Data Arrays
    xls_methode = String[]
    xls_instance = String[]
    xls_statut = String[]
    xls_temps_inst = Float64[]
    xls_temps_cumul = Float64[]
    xls_obj = Any[]
    xls_gap = Any[]

    csv_file = joinpath(output_dir, "log_live_$(timestamp).csv")
    open(csv_file, "w") do f; println(f, "Methode;Instance;Statut;Temps_Instance;Temps_Cumule;Objectif;Gap"); end

    # --- BOUCLE PRINCIPALE : PAR MÉTHODE ---
    for (method_name, solver_func) in solvers
        println("\n" * "█"^92)
        println(" 🔹 DÉMARRAGE MÉTHODE : $method_name")
        println("█"^92)
        
        # Initialisation du chrono global pour CETTE méthode
        global_start_time = time()
        cumulative_elapsed = 0.0
        solved_count = 0
        
        results_for_plot[method_name] = []

        @printf "%-25s | %-12s | %-10s | %-10s | %-10s\n" "Instance" "Statut" "T. Inst" "T. Cumul" "Obj"
        println("-"^92)

        # --- BOUCLE SECONDAIRE : PAR INSTANCE ---
        for filepath in instance_files
            inst_name = basename(filepath)
            
            # 1. Vérification du budget restant
            current_elapsed = time() - global_start_time
            remaining_time = global_time_limit - current_elapsed
            
            # Si moins de 1 seconde restante, on arrête cette méthode
            if remaining_time < 1.0
                println(" ⚠️ Temps écoulé pour $method_name (Timeout Global). Arrêt des instances.")
                break
            end

            limit_for_instance = floor(Int, remaining_time)
            
            t0_instance = time()
            status_code = MOI.OTHER_ERROR
            obj = Inf
            gap = Inf
            is_solved = false
            
            # --- CORRECTION ICI : Initialisation de t_instance AVANT le try ---
            t_instance = 0.0 
            
            try
                instance = read_instance_file(filepath) 
                
                # APPEL DU SOLVEUR
                model = solver_func(instance, limit_for_instance)
                
                # Analyse résultats
                status_code = termination_status(model)
                t_instance = time() - t0_instance
                
                if has_values(model)
                    obj = objective_value(model)
                    try
                        val_gap = MOI.get(model, MOI.RelativeGap())
                        gap = (val_gap > 1e10) ? Inf : val_gap
                    catch; end
                    
                    # CRITÈRE DE SUCCÈS
                    if status_code == MOI.OPTIMAL || (gap <= gap_limit)
                        is_solved = true
                        solved_count += 1
                    end
                end

            catch e
                t_instance = time() - t0_instance
                println("   ❌ Erreur exécution $inst_name : $e")
            end
            
            # Mise à jour du temps cumulé RÉEL
            cumulative_elapsed = time() - global_start_time
            
            # Stockage Graphique
            push!(results_for_plot[method_name], (t_instance, is_solved))
            
            # Affichage console
            status_str = is_solved ? "✅ RÉSOLU" : "❌ ÉCHEC"
            obj_str = (obj == Inf) ? "-" : @sprintf("%.2f", obj)
            @printf "%-25s | %-12s | %-10.2f | %-10.2f | %-10s\n" inst_name status_str t_instance cumulative_elapsed obj_str
            
            # Stockage Excel/CSV
            push!(xls_methode, method_name)
            push!(xls_instance, inst_name)
            push!(xls_statut, string(status_code))
            push!(xls_temps_inst, t_instance)
            push!(xls_temps_cumul, cumulative_elapsed)
            push!(xls_obj, obj)
            push!(xls_gap, gap)
            
            open(csv_file, "a") do f
                println(f, "$method_name;$inst_name;$status_code;$t_instance;$cumulative_elapsed;$obj;$gap")
            end
        end
        
        println(" >> Bilan $method_name : $solved_count instances résolues en $(round(cumulative_elapsed, digits=1)) s")
    end

    # --- GÉNÉRATION FICHIERS FINAUX ---
    println("\n" * "="^90)
    println(" 💾 Sauvegarde des résultats...")

    # 1. Excel
    excel_path = joinpath(output_dir, "benchmark_budget_$(timestamp).xlsx")
    try
        XLSX.writetable(excel_path, 
            Methode      = xls_methode,
            Instance     = xls_instance,
            Statut       = xls_statut,
            Temps_Inst   = xls_temps_inst,
            Temps_Cumul  = xls_temps_cumul,
            Objectif     = xls_obj,
            Gap          = xls_gap,
            overwrite = true
        )
        println(" ✅ Excel créé : $excel_path")
    catch e
        println(" ⚠️ Erreur Excel : $e")
    end

    # 2. Graphique
    try
        plot_path = joinpath(output_dir, "courbe_resolution_$(timestamp).png")
        plot_cumulative_solved(results_for_plot, global_time_limit, plot_path)
    catch e
        println(" ⚠️ Erreur Graphique : $e")
    end

    return results_for_plot
end

# 1. Définir tes fichiers (Assure-toi de l'ordre !)
# Exemple : on prend tout le dossier et on trie par taille de fichier (souvent corrélé à la difficulté)
dir = "data/data"
files = readdir(dir, join=true)
instances = filter(x -> endswith(x, ".tsp"), files)

# Fonction simple pour trier par taille (n=10 avant n=100)
# On extrait le nombre après le dernier '/' et avant '_' (ex: 10_ulysses -> 10)
function get_size(path)
    name = basename(path)
    m = match(r"(\d+)_", name)
    return m === nothing ? 9999 : parse(Int, m.captures[1])
end
sort!(instances, by=get_size)

# 2. Lancer le benchmark (30 minutes = 1800 secondes par méthode)
benchmark_global_budget(instances, global_time_limit=1440, gap_limit=0.06)