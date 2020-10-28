module NoncommutativeGraphs

import Base.==

using Subspaces
using Convex, SCS, LinearAlgebra

export AlgebraShape
export S0Graph
export random_S0Graph, complement, vertex_graph, forget_S0
export from_block_spaces, get_block_spaces

export Ψ
export dsw_schur!, dsw_schur2!, dsw
export dsw_min_X_diag
export dsw_antiblocker
export dsw_antiblocker_S0

AlgebraShape = Array{<:Integer, 2}

function create_S0_S1(sig::AlgebraShape)
    blocks0 = []
    blocks1 = []
    for row in eachrow(sig)
        if length(row) != 2
            throw(ArgumentError("row length must be 2"))
        end
        dA = row[1]
        dY = row[2]
        #println("dA=$dA dY=$dY")
        blk0 = kron(full_subspace((dA, dA)), Matrix((1.0+0.0im)*I, dY, dY))
        blk1 = kron(Matrix((1.0+0.0im)*I, dA, dA), full_subspace((dY, dY)))
        #println(blk0)
        push!(blocks0, blk0)
        push!(blocks1, blk1)
    end

    S0 = cat(blocks0..., dims=(1,2))
    S1 = cat(blocks1..., dims=(1,2))

    @assert I in S0
    @assert I in S1
    s0 = random_element(S0)
    s1 = random_element(S1)
    @assert (norm(s0 * s1 - s1 * s0) < 1e-9) "S0 and S1 don't commute"

    return S0, S1
end

struct S0Graph
    n::Integer
    sig::AlgebraShape
    S::Subspace{Complex{Float64}, 2}
    S0::Subspace{Complex{Float64}, 2}
    S1::Subspace{Complex{Float64}, 2} # commutant of S0

    function S0Graph(sig::AlgebraShape, S::Subspace{Complex{Float64}, 2})
        S0, S1 = create_S0_S1(sig)
        n = shape(S0)[1]
        S == S' || throw(DomainError("S is not an S0-graph"))
        S0 in S || throw(DomainError("S is not an S0-graph"))
        (S == S0 * S * S0) || throw(DomainError("S is not an S0-graph"))
        return new(n, sig, S, S0, S1)
    end
end

function show(io::IO, g::S0Graph)
    print(io, "S0Graph{S0=$(g.sig) S=$(g.S)}")
end

vertex_graph(g::S0Graph) = S0Graph(g.sig, g.S0)

forget_S0(g::S0Graph) = S0Graph([1 g.n], g.S)

function random_S0Graph(sig::AlgebraShape)
    S0, S1 = create_S0_S1(sig)

    num_blocks = size(sig, 1)
    function block(col, row)
        da_col, dy_col = sig[col,:]
        da_row, dy_row = sig[row,:]
        ds = Integer(round(sqrt(dy_row * dy_col) / 2.0))
        F = full_subspace((da_row, da_col))
        if row == col
            R = random_hermitian_subspace(ds, dy_row)
        elseif row > col
            R = random_subspace(ds, (dy_row, dy_col))
        else
            R = empty_subspace((dy_row, dy_col))
        end
        kron(F, R)
    end
    blocks = [
        block(col, row)
        for col in 1:num_blocks, row in 1:num_blocks
    ]

    S = hvcat(num_blocks, blocks...)
    S |= S'
    S |= S0

    return S0Graph(sig, S)
end

complement(g::S0Graph) = S0Graph(g.sig, perp(g.S) | g.S0)

function ==(a::S0Graph, b::S0Graph)
    return a.sig == b.sig && a.S == b.S
end

function get_block_spaces(g::S0Graph)
    num_blocks = size(g.sig, 1)
    da_sizes = g.sig[:,1]
    dy_sizes = g.sig[:,2]
    n_sizes = da_sizes .* dy_sizes

    blkspaces = Array{Subspace{Complex{Float64}}, 2}(undef, num_blocks, num_blocks)
    offseti = 0
    for blki in 1:num_blocks
        offsetj = 0
        for blkj in 1:num_blocks
            #@show [blki, blkj, offseti, offsetj]
            blkbasis = Array{Array{Complex{Float64}, 2}, 1}()
            for m in each_basis_element(g.S)
                blk = m[1+offseti:dy_sizes[blki]+offseti, 1+offsetj:dy_sizes[blkj]+offsetj]
                push!(blkbasis, blk)
            end
            blkspaces[blki, blkj] = Subspace(blkbasis)
            #println(blkspaces[blki, blkj])
            offsetj += n_sizes[blkj]
        end
        @assert offsetj == shape(g.S)[2]
        offseti += n_sizes[blki]
    end
    @assert offseti == shape(g.S)[1]

    return blkspaces
end

function from_block_spaces(sig::AlgebraShape, blkspaces::Array{Subspace{Complex{Float64}}, 2})
    S0, S1 = NoncommutativeGraphs.create_S0_S1(sig)

    num_blocks = size(sig, 1)
    function block(col, row)
        da_col, dy_col = sig[col,:]
        da_row, dy_row = sig[row,:]
        ds = Integer(round(sqrt(dy_row * dy_col) / 2.0))
        F = full_subspace((da_row, da_col))
        kron(F, blkspaces[row, col])
    end
    blocks = [
        block(col, row)
        for col in 1:num_blocks, row in 1:num_blocks
    ]

    S = hvcat(num_blocks, blocks...)
    S |= S'
    S |= S0

    return S0Graph(sig, S)
end

###############
### DSW solvers
###############

function diagcat(args::Convex.AbstractExprOrValue...)
    # FIXME Convex.jl doesn't support cat(args..., dims=(1,2)).  It should be added.

    num_blocks = size(args, 1)
    #if num_blocks == 1
    #    return args[1]
    #end
    return vcat([
        hcat([
            row == col ? args[row] : zeros(size(args[row], 1), size(args[col], 2))
            for col in 1:num_blocks
        ]...)
        for row in 1:num_blocks
    ]...)
end

function Ψ(g::S0Graph, w::Union{AbstractArray{<:Number, 2}, Variable})
    n = g.n
    da_sizes = g.sig[:,1]
    dy_sizes = g.sig[:,2]
    n_sizes = da_sizes .* dy_sizes
    num_blocks = size(g.sig)[1]

    k = 0
    blocks = []
    for (dai, dyi) in zip(da_sizes, dy_sizes)
        ni = dai * dyi
        TrAi = partialtrace(w[k+1:k+ni, k+1:k+ni], 1, [dai; dyi])
        blk = dyi^-1 * kron(Array(1.0*I, dai, dai), TrAi)
        k += ni
        push!(blocks, blk)
    end
    @assert k == n
    out = diagcat(blocks...)
    @assert size(out) == (n, n)
    return out
end

function dsw_schur!(g::S0Graph)
    n = shape(g.S)[1]

    function make_var(m)
        # FIXME it'd be nice to have HermitianVariable
        Z = ComplexVariable(n, n)
        add_constraint!(Z, Z == Z')
        return kron(m, Z)
    end
    Z = sum(make_var(m) for m in hermitian_basis(g.S))

    λ = Variable()
    w = partialtrace(Z, 1, [n; n])
    wv = reshape(w, n*n, 1)

    add_constraint!(λ, [ λ  wv' ; wv  Z ] ⪰ 0)

    # FIXME maybe need transpose
    return λ, w, Z
end

#function dsw_schur2!(constraints::Array{Constraint,1}, g::S0Graph)
#    λ, x, Z = dsw_schur!(constraints, g)
#
#    # FIXME should exploit symmetries to reduce degrees of freedom
#    # (e.g. if S1=diags then Z is block diagonal)
#    for m in each_basis_element(perp(g.S1))
#        push!(constraints, tr(m' * x) == 0)
#    end
#
#    return λ, x, Z
#end
#
#function dsw_min_X_diag(g::S0Graph, w::AbstractArray{<:Number, 2})
#    constraints = Array{Constraint,1}()
#    λ, x, Z = dsw_schur2!(constraints, g)
#
#    push!(constraints, x ⪰ w)
#    problem = minimize(λ, constraints)
#
#    solve!(problem, () -> SCS.Optimizer(verbose=0))
#
#    x = evaluate(x)
#    xproj = projection(g.S1, x)
#    println("proj err: ", norm(x - xproj))
#    return problem.optval, xproj, evaluate(Z)
#end

# Like dsw_schur except much faster (when S0 != I), but w is constrained to S1.
function dsw_schur2!(g::S0Graph)
    da_sizes = g.sig[:,1]
    dy_sizes = g.sig[:,2]
    n_sizes = da_sizes .* dy_sizes
    num_blocks = size(g.sig)[1]
    d = sum(dy_sizes .^ 2)

    eye(n) = Matrix(1.0*I, (n,n))

    blkspaces = get_block_spaces(g)
    Z = ComplexVariable(d, d)

    blkw = []
    offseti = 0
    for blki in 1:num_blocks
        offsetj = 0
        ni = dy_sizes[blki]^2
        for blkj in 1:num_blocks
            nj = dy_sizes[blkj]^2
            #@show [ni, nj]
            #@show [1+offseti:ni+offseti, 1+offsetj:nj+offsetj]
            blkZ = Z[1+offseti:ni+offseti, 1+offsetj:nj+offsetj]
            #@show size(blkZ)
            if blkj <= blki
                p = kron(
                    perp(blkspaces[blki, blkj]),
                    full_subspace((dy_sizes[blki], dy_sizes[blkj])))
                for m in each_basis_element(p)
                    add_constraint!(Z, tr(m' * blkZ) == 0)
                end
            end
            if blkj == blki
                wi = partialtrace(blkZ, 1, [dy_sizes[blki], dy_sizes[blkj]])
                push!(blkw, wi)
            end
            offsetj += nj
        end
        #@show [offsetj, d]
        @assert offsetj == d
        offseti += ni
    end
    @assert offseti == d

    #@show [ size(wi) for wi in blkw ]

    λ = Variable()
    wv = vcat([ reshape(wi, dy_sizes[i]^2, 1) for (i,wi) in enumerate(blkw) ]...)
    #@show size(wv)
    #@show size(Z)

    add_constraint!(λ, [ λ  wv' ; wv  Z ] ⪰ 0)

    w = diagcat([ kron(eye(da_sizes[i]), wi) for (i,wi) in enumerate(blkw) ]...)
    #@show size(w)

    # FIXME maybe need transpose
    return λ, w, Z
end

function dsw(g::S0Graph, w::AbstractArray{<:Number, 2}; use_diag_optimization=true)
    if use_diag_optimization
        return dsw_min_X_diag(g, w)
    else
        constraints = Array{Constraint,1}()
        λ, x, Z = dsw_schur!(g)

        push!(constraints, x ⪰ w)
        problem = minimize(λ, constraints)

        solve!(problem, () -> SCS.Optimizer(verbose=0))
        return problem.optval, evaluate(x), evaluate(Z)
    end
end

function dsw_antiblocker(g::S0Graph, w::AbstractArray{<:Number, 2}; use_diag_optimization=true)
    if use_diag_optimization
        # max{ <w,q> : Ψ(S, q) ⪯ y, ϑ(S, y) ≤ 1, y ∈ S1 }
        # equal to:
        # max{ dsw(S0, √y * w * √y) : dsw(complement(S), y) <= 1 }

        constraints = Array{Constraint,1}()
        λ, x, Z = dsw_schur2!(g)
        z = HermitianSemidefinite(g.n, g.n)

        push!(constraints, λ <= 1)
        push!(constraints, Ψ(g, z) == x)
        problem = maximize(real(tr(w * z')), constraints)

        solve!(problem, () -> SCS.Optimizer(verbose=0))
        return problem.optval, evaluate(x)
    else
        constraints = Array{Constraint,1}()
        λ, x, Z = dsw_schur!(g)

        push!(constraints, λ <= 1)
        problem = maximize(real(tr(w * x')), constraints)

        solve!(problem, () -> SCS.Optimizer(verbose=0))
        return problem.optval, evaluate(x)
    end
end

function dsw_min_X_diag(g::S0Graph, w::AbstractArray{<:Number, 2})
    constraints = Array{Constraint,1}()
    λ, x, Z = dsw_schur2!(g)

    push!(constraints, x ⪰ w)
    problem = minimize(λ, constraints)

    solve!(problem, () -> SCS.Optimizer(verbose=0))

    return problem.optval, evaluate(x), evaluate(Z)
end

# max{ dsw(S0, √y * w * √y) : dsw(perp(S)+S0, y) <= 1 }
# We can assume (y in S1) because those are the extreme points.
# eq:max_WZ used to relate dsw(S0, .) to |Ψ(x)|
#function dsw_antiblocker_v3(g::S0Graph, w::AbstractArray{<:Number, 2})
#    n = g.n
#    da_sizes = g.sig[:,1]
#    dy_sizes = g.sig[:,2]
#
#    constraints = Array{Constraint,1}()
#    λ, y, Z = dsw_schur2!(constraints, g)
#    push!(constraints, λ <= 1)
#
#    q = HermitianSemidefinite(n)
#
#    k = 0
#    for (dai, dyi) in zip(da_sizes, dy_sizes)
#        ni = dai * dyi
#        TrAi_q = partialtrace(q[k+1:k+ni, k+1:k+ni], 1, [dai; dyi])
#        TrAi_y = partialtrace(y[k+1:k+ni, k+1:k+ni], 1, [dai; dyi])
#        push!(constraints, (ni * dai^-2 * TrAi_y) ⪰ TrAi_q)
#        k += ni
#    end
#    @assert k == n
#
#    problem = maximize(real(tr(w * q')), constraints)
#
#    solve!(problem, () -> SCS.Optimizer(verbose=0))
#
#    y = evaluate(y)
#    yproj = projection(g.S1, y)
#    println("proj err: ", norm(y - yproj))
#    return problem.optval, yproj, evaluate(q)
#end
