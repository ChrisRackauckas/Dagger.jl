import Base: reduce, map, mapreduce, reducedim

export reducebykey, reduce_async

#### Map
immutable Map{T,N} <: LazyArray{T,N}
    f::Function
    inputs::Tuple
end
size(x::Map) = size(x.inputs[1])

Map(f, inputs::Tuple) = Map{Any, ndims(inputs[1])}(f, inputs)

function stage(ctx, node::Map)
    inputs = Any[cached_stage(ctx, n) for n in node.inputs]
    primary = inputs[1] # all others will align to this guy
    domains = parts(domain(primary))
    thunks = similar(domains, Any)
    f = node.f
    for i=eachindex(domains)
        inps = map(x->parts(x)[i], inputs)
        thunks[i] = Thunk((args...) -> map(f, args...), (inps...))
    end
    Cat(Any, domain(primary), thunks)
end

map(f, xs::LazyArray...) = Map(f, xs)
map(f, x::AbstractPart) = map(f, Computed(x))
map(f, x::Thunk) = Thunk(x->map(f,x), x)

#### Reduce

import Base: reduce, sum, prod, mean

immutable ReduceBlock <: Computation
    op::Function
    op_master::Function
    input::LazyArray
    get_result::Bool
end

function stage(ctx, r::ReduceBlock)
    inp = stage(ctx, r.input)
    let op=r.op
        reduced_parts = map(x -> Thunk(p->reduce(op,p), (x,)), parts(inp))
    #Thunk((xs...) -> r.op_master(xs), (reduced_parts...); meta=true)
        treereduce((x,y)->Thunk(op, (x,y)), reduced_parts)
    end
end

reduceblock_async(f, x::LazyArray; get_result=true) = ReduceBlock(f, f, x, get_result)
reduceblock_async(f, g::Function, x::LazyArray; get_result=true) = ReduceBlock(f, g, x, get_result)

reduceblock(f, x::LazyArray) = compute(reduceblock_async(f, x))
reduceblock(f, g::Function, x::LazyArray) =
    compute(reduceblock_async(f, g, x))

reduce_async(f, x::LazyArray) = reduceblock_async(f, f, x)

reduce(f, x::LazyArray) = compute(reduce_async(f,x))

sum(x::LazyArray) = reduceblock(sum, sum, x)
sum(x::LazyArray, dim::Int) = reducedim(+, x, dim)
sum(f::Function, x::LazyArray) = reduceblock(a->sum(f, a), sum, x)
prod(x::LazyArray) = reduceblock(prod, x)
prod(f::Function, x::LazyArray) = reduceblock(a->prod(f, a), prod, x)

mean(x::LazyArray) = reduceblock(mean, mean, x)

mapreduce(f::Function, g::Function, x::LazyArray) = reduce(g, map(f, x))

function mapreducebykey_seq(f, op,  itr, dict=Dict())
    for x in itr
        y = f(x)
        if haskey(dict, y[1])
            dict[y[1]] = op(dict[y[1]], y[2])
        else
            dict[y[1]] = y[2]
        end
    end
    dict
end

function merge_reducebykey(op)
    xs -> reduce((d,x) -> reducebykey_seq(op, x, d), Dict(), xs)
end
reducebykey_seq(op, itr,dict=Dict()) = mapreducebykey_seq(Base.IdFun(), op, itr, dict)
reducebykey(op, input) = reduceblock(itr->reducebykey_seq(op, itr), merge_reducebykey(op), input)


immutable Reducedim{T,N} <: LazyArray{T,N}
    op::Function
    input::LazyArray
    dims::Tuple
    v0
end

function reducedim(dom::DenseDomain, dim::Int)
    DenseDomain(setindex(indexes(dom), dim, 1:1))
end

function reducedim(dom::DenseDomain, dim::Tuple)
    reduce(reducedim, dom, dim)
end

function size(x::Reducedim)
    reducedim(DenseDomain(map(x->1:x, size(x.input))), x.dims)
end

function Reducedim(op, input, dims,v0)
    T = eltype(input)
    Reducedim{T,ndims(input)}(op, input, dims,v0)
end

Base.reducedim(f, x::LazyArray, dims::Tuple,v0) = Reducedim(f,x,dims,v0)
Base.reducedim(f, x::LazyArray, dims::Int,v0) = Reducedim(f,x,(dims,),v0)

function stage(ctx, r::Reducedim)
    inp = cached_stage(ctx, r.input)
    thunks = let op = r.op, dims=r.dims,v0=r.v0
        # do reducedim on each block
        tmp = map(p->Thunk(b->reducedim(op,b,dims,v0), (p,)), parts(inp))
        # combine the results in tree fashion
        treereducedim(tmp, r.dims) do x,y
            Thunk(op, (x,y,))
        end
    end
    c = parts(domain(inp))
    colons = Any[Colon() for x in size(c)]
    nd=ndims(domain(inp))
    colons[[filter(d->d<=nd, r.dims)...]] = 1
    dmn = c[colons...]
    d = DomainSplit(reducedim(head(domain(inp)), r.dims), reducedim(parts(domain(inp)), r.dims))
    Cat(parttype(inp),d, thunks)
end
