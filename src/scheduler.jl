module Sch

using Distributed
import MemPool: DRef

import ..Dagger: Context, Processor, Thunk, Chunk, OSProc, order, free!, dependents, noffspring, istask, inputs, affinity, tochunk, @dbg, @logmsg, timespan_start, timespan_end, unrelease, procs, move, choose_processor, execute!

include("fault-handler.jl")

const OneToMany = Dict{Thunk, Set{Thunk}}

"A handle to the scheduler, used by dynamic thunks."
struct SchedulerHandle
    thunk_id::Int
    out_chan::RemoteChannel
    inp_chan::RemoteChannel
end

"Thrown when the scheduler halts before finishing processing the DAG."
struct SchedulerHaltedException <: Exception end

## Worker-side methods for dynamic communication

"Sends arbitrary data to the scheduler."
send!(h::SchedulerHandle, cmd, data) = put!(h.out_chan, (h.thunk_id, cmd, data))

"Receives the next message from the scheduler."
recv!(h::SchedulerHandle) = take!(h.inp_chan)

"Commands the scheduler to halt execution immediately."
function halt!(h::SchedulerHandle)
    send!(h, :halt, nothing)
    sleep(1)
end

"Returns all Thunks IDs as a Dict, mapping a Thunk to its inputs."
get_dag_ids(h::SchedulerHandle) = (send!(h, :get_dag_ids, nothing); recv!(h))

## Scheduler-side methods for dynamic communication

# Fallback method
function process_dynamic!(state, task, tid, cmd, data)
    @warn "Received invalid dynamic command $cmd from thunk $tid: $data"
    Base.throwto(task, SchedulerHaltedException())
end

function process_dynamic!(state, task, tid, cmd::Val{:halt}, _)
    state.halt[] = true
    Base.throwto(task, SchedulerHaltedException())
end
function safepoint(state, chan)
    if state.halt[]
        # Force dynamic thunks and listeners to terminate
        for (inp_chan,out_chan) in values(state.worker_chans)
            close(inp_chan)
            close(out_chan)
        end
        # Throw out of scheduler
        throw(SchedulerHaltedException())
    end
end

function process_dynamic!(state, task, tid, cmd::Val{:get_dag_ids}, _)
    deps = Dict{Int,Set{Int}}()
    for (key,val) in state.dependents
        deps[key.id] = Set(map(t->t.id, collect(val)))
    end
    deps
end

"Processes dynamic messages from worker-executing thunks."
function dynamic_listener!(state)
    task = current_task()
    for tid in keys(state.worker_chans)
        inp_chan, out_chan = state.worker_chans[tid]
        @async begin
            while isopen(inp_chan)
                tid, cmd, data = take!(inp_chan)
                res = process_dynamic!(state, task, tid, Val(cmd), data)
                res !== nothing && put!(out_chan, res)
            end
        end
    end
end

"""
    ComputeState

The internal state-holding struct of the scheduler.

Fields
- dependents::OneToMany - The result of calling `dependents` on the DAG
- finished::Set{Thunk} - The set of completed `Thunk`s
- waiting::OneToMany - Map from parent `Thunk` to child `Thunk`s that still need to execute
- waiting_data::OneToMany - Map from child `Thunk` to all parent `Thunk`s, accumulating over time
- ready::Vector{Thunk} - The list of `Thunk`s that are ready to execute
- cache::Dict{Thunk, Any} - Maps from a finished `Thunk` to it's cached result, often a DRef
- running::Set{Thunk} - The set of currently-running `Thunk`s
- thunk_dict::Dict{Int, Any} - Maps from thunk IDs to a `Thunk`
- worker_chans::Dict{Int, Tuple{RemoteChannel,RemoteChannel}} - Communication channels between the scheduler and each worker
- halt::Ref{Bool} - Flag indicating, when set, that the scheduler should halt immediately
- lock::ReentrantLock() - Lock around operations which modify the state
"""
struct ComputeState
    dependents::OneToMany
    finished::Set{Thunk}
    waiting::OneToMany
    waiting_data::OneToMany
    ready::Vector{Thunk}
    cache::Dict{Thunk, Any}
    running::Set{Thunk}
    thunk_dict::Dict{Int, Any}
    worker_chans::Dict{Int, Tuple{RemoteChannel,RemoteChannel}}
    halt::Ref{Bool}
    lock::ReentrantLock
end

"""
    SchedulerOptions

Stores DAG-global options to be passed to the Dagger.Sch scheduler.

# Arguments
- `single::Int=0`: Force all work onto worker with specified id. `0` disables this option.
"""
Base.@kwdef struct SchedulerOptions
    single::Int = 0
    proctypes::Vector{Type} = Type[]
end

"""
    ThunkOptions

Stores Thunk-local options to be passed to the Dagger.Sch scheduler.

# Arguments
- `single::Int=0`: Force thunk onto worker with specified id. `0` disables this option.
- `proctypes::Vector{Type{<:Processor}}=Type[]`: Force thunk to use one or
more processors that are instances/subtypes of a contained type. Leave this
vector empty to disable.
"""
Base.@kwdef struct ThunkOptions
    single::Int = 0
    proctypes::Vector{Type} = Type[]
end

"Combine `SchedulerOptions` and `ThunkOptions` into a new `ThunkOptions`."
function merge(sopts::SchedulerOptions, topts::ThunkOptions)
    single = topts.single != 0 ? topts.single : sopts.single
    proctypes = vcat(sopts.proctypes, topts.proctypes)
    ThunkOptions(single, proctypes)
end

function cleanup(ctx)
end

function compute_dag(ctx, d::Thunk; options=SchedulerOptions())
    if options === nothing
        options = SchedulerOptions()
    end
    ctx.options = options
    master = OSProc(myid())
    @dbg timespan_start(ctx, :scheduler_init, 0, master)

    if options.single !== 0
        @assert options.single in vcat(1, workers()) "Sch option 'single' must specify an active worker id"
        ps = OSProc[OSProc(options.single)]
    else
        ps = procs(ctx)
    end
    chan = Channel{Any}(32)
    deps = dependents(d)
    ord = order(d, noffspring(deps))

    node_order = x -> -get(ord, x, 0)
    state = start_state(deps, node_order)

    # setup worker-to-scheduler channels
    for p in ps
        inp_chan = RemoteChannel(p.pid)
        out_chan = RemoteChannel(p.pid)
        state.worker_chans[p.pid] = (inp_chan, out_chan)
    end

    # setup dynamic listeners
    @async dynamic_listener!(state)

    @dbg timespan_end(ctx, :scheduler_init, 0, master)

    # start off some tasks
    for p in ps
        isempty(state.ready) && break
        lock(state.lock) do
            task = pop_with_affinity!(ctx, state.ready, p, false)
            if task !== nothing
                fire_task!(ctx, task, p, state, chan, node_order)
            end
        end
    end

    safepoint(state, chan)

    # Loop while we still have thunks to execute
    while !isempty(state.ready) || !isempty(state.running)
        if isempty(state.running) && !isempty(state.ready)
            # Nothing running, so schedule up to N thunks, 1 per N workers
            for p in ps
                isempty(state.ready) && break
                lock(state.lock) do
                    task = pop_with_affinity!(ctx, state.ready, p, false)
                    if task !== nothing
                        fire_task!(ctx, task, p, state, chan, node_order)
                    end
                end
            end
        end

        if isempty(state.running)
            # the block above fired only meta tasks
            continue
        end

        safepoint(state, chan)

        proc, thunk_id, res = take!(chan) # get result of completed thunk
        if isa(res, CapturedException) || isa(res, RemoteException)
            if check_exited_exception(res)
                @warn "Worker $(proc.pid) died on thunk $thunk_id, rescheduling work"

                # Remove dead worker from procs list
                filter!(p->p.pid!=proc.pid, ctx.procs)
                ps = procs(ctx)

                lock(state.lock)
                handle_fault(ctx, state, state.thunk_dict[thunk_id], proc, chan, node_order)
                unlock(state.lock)
                continue
            else
                throw(res)
            end
        end
        node = state.thunk_dict[thunk_id]
        @logmsg("WORKER $(proc.pid) - $node ($(node.f)) input:$(node.inputs)")
        state.cache[node] = res

        @dbg timespan_start(ctx, :scheduler, thunk_id, master)
        lock(state.lock) do
            immediate_next = finish_task!(state, node, node_order)
            if !isempty(state.ready)
                thunk = pop_with_affinity!(Context(ps), state.ready, proc, immediate_next)
                if thunk !== nothing
                    fire_task!(ctx, thunk, proc, state, chan, node_order)
                end
            end
        end
        @dbg timespan_end(ctx, :scheduler, thunk_id, master)

        safepoint(state, chan)
    end
    state.cache[d]
end

function pop_with_affinity!(ctx, tasks, proc, immediate_next)
    # allow JIT specialization on Pairs
    mapfirst(c) = first.(c)

    if immediate_next
        # fast path
        if proc in mapfirst(affinity(tasks[end]))
            return pop!(tasks)
        end
    end

    # TODO: use the size
    parent_affinity_procs = Vector(undef, length(tasks))
    # parent_affinity_sizes = Vector(undef, length(tasks))
    for i=length(tasks):-1:1
        t = tasks[i]
        aff = affinity(t)
        aff_procs = mapfirst(aff)
        if proc in aff_procs
            deleteat!(tasks, i)
            return t
        end
        parent_affinity_procs[i] = aff_procs
    end
    for i=length(tasks):-1:1
        # use up tasks without affinities
        # let the procs with the respective affinities pick up
        # other tasks
        aff_procs = parent_affinity_procs[i]
        if isempty(aff_procs)
            t = tasks[i]
            deleteat!(tasks, i)
            return t
        end
        if all(!(p in aff_procs) for p in procs(ctx))
            # no proc is ever going to ask for it
            t = tasks[i]
            deleteat!(tasks, i)
            return t
        end
    end
    return nothing
end

function fire_task!(ctx, thunk, proc, state, chan, node_order)
    @logmsg("W$(proc.pid) + $thunk ($(showloc(thunk.f, length(thunk.inputs)))) input:$(thunk.inputs) cache:$(thunk.cache) $(thunk.cache_ref)")
    push!(state.running, thunk)
    if thunk.cache && thunk.cache_ref !== nothing
        # the result might be already cached
        data = unrelease(thunk.cache_ref) # ask worker to keep the data around
                                          # till this compute cycle frees it
        if data !== nothing
            @logmsg("cache hit: $(thunk.cache_ref)")
            state.cache[thunk] = data
            immediate_next = finish_task!(state, thunk, node_order; free=false)
            if !isempty(state.ready)
                thunk = pop_with_affinity!(ctx, state.ready, proc, immediate_next)
                if thunk !== nothing
                    fire_task!(ctx, thunk, proc, state, chan, node_order)
                end
            end
            return
        else
            thunk.cache_ref = nothing
            @logmsg("cache miss: $(thunk.cache_ref) recomputing $(thunk)")
        end
    end

    if thunk.meta
        # Run it on the parent node
        # do not move data.
        p = OSProc(myid())
        @dbg timespan_start(ctx, :comm, thunk.id, p)
        fetched = map(thunk.inputs) do x
            istask(x) ? state.cache[x] : x
        end
        @dbg timespan_end(ctx, :comm, thunk.id, p)

        @dbg timespan_start(ctx, :compute, thunk.id, p)
        res = thunk.f(fetched...)
        @dbg timespan_end(ctx, :compute, thunk.id, p)

        #push!(state.running, thunk)
        state.cache[thunk] = res
        immediate_next = finish_task!(state, thunk, node_order; free=false)
        if !isempty(state.ready)
            if immediate_next
                thunk = pop!(state.ready)
            else
                thunk = pop_with_affinity!(ctx, state.ready, proc, immediate_next)
            end
            if thunk !== nothing
                fire_task!(ctx, thunk, proc, state, chan, node_order)
            end
        end
        return
    end

    data = map(thunk.inputs) do x
        istask(x) ? state.cache[x] : x
    end
    state.thunk_dict[thunk.id] = thunk
    toptions = thunk.options !== nothing ? thunk.options : ThunkOptions()
    options = merge(ctx.options, toptions)
    if options.single > 0
        proc = OSProc(options.single)
    end
    sch_handle = if thunk.dynamic
        SchedulerHandle(thunk.id, state.worker_chans[proc.pid]...)
    else
        nothing
    end
    async_apply(ctx, proc, thunk.id, thunk.f, data, chan, thunk.get_result,
                thunk.persist, thunk.cache, options, sch_handle)
end

function finish_task!(state, node, node_order; free=true)
    if istask(node) && node.cache
        node.cache_ref = state.cache[node]
    end
    immediate_next = false
    for dep in sort!(collect(state.dependents[node]), by=node_order)
        set = state.waiting[dep]
        pop!(set, node)
        if isempty(set)
            pop!(state.waiting, dep)
            push!(state.ready, dep)
            immediate_next = true
        end
        # todo: free data
    end
    for inp in inputs(node)
        if inp in keys(state.waiting_data)
            s = state.waiting_data[inp]
            if node in s
                pop!(s, node)
            end
            if free && isempty(s)
                if haskey(state.cache, inp)
                    _node = state.cache[inp]
                    free!(_node, force=false, cache=(istask(inp) && inp.cache))
                    pop!(state.cache, inp)
                end
            end
        end
    end
    push!(state.finished, node)
    pop!(state.running, node)
    immediate_next
end

function start_state(deps::Dict, node_order)
    state = ComputeState(
                  deps,
                  Set{Thunk}(),
                  OneToMany(),
                  OneToMany(),
                  Vector{Thunk}(undef, 0),
                  Dict{Thunk, Any}(),
                  Set{Thunk}(),
                  Dict{Int, Thunk}(),
                  Dict{Int, Tuple{RemoteChannel,RemoteChannel}}(),
                  Ref{Bool}(false),
                  ReentrantLock()
                 )

    nodes = sort(collect(keys(deps)), by=node_order)
    # N.B. Using merge! here instead would modify deps
    for (key,val) in deps
        state.waiting_data[key] = copy(val)
    end
    for k in nodes
        if istask(k)
            waiting = Set{Thunk}(Iterators.filter(istask,
                                                  inputs(k)))
            if isempty(waiting)
                push!(state.ready, k)
            else
                state.waiting[k] = waiting
            end
        end
    end
    state
end

_move(ctx, to_proc, x) = x
_move(ctx, to_proc::OSProc, x::Union{Chunk, Thunk}) = collect(ctx, x)

@noinline function do_task(ctx, proc, thunk_id, f, data, send_result, persist, cache, options, sch_handle)
    @dbg timespan_start(ctx, :comm, thunk_id, proc)
    fetched = map(x->x isa Union{Chunk,Thunk} ? collect(ctx, x) : x, data)
    @dbg timespan_end(ctx, :comm, thunk_id, proc)

    @dbg timespan_start(ctx, :compute, thunk_id, proc)
    from_proc = proc
    to_proc = choose_processor(from_proc, options, f, fetched)
    fetched = move.(Ref(ctx), Ref(from_proc), Ref(to_proc), fetched)
    if sch_handle !== nothing
        fetched = (sch_handle, fetched...) # prepend scheduler handle
    end
    result_meta = try
        res = execute!(to_proc, f, fetched...)
        (from_proc, thunk_id, send_result ? res : tochunk(res, to_proc; persist=persist, cache=persist ? true : cache)) #todo: add more metadata
    catch ex
        bt = catch_backtrace()
        (from_proc, thunk_id, RemoteException(myid(), CapturedException(ex, bt)))
    end
    @dbg timespan_end(ctx, :compute, thunk_id, proc)
    result_meta
end

@noinline function async_apply(ctx, p::OSProc, thunk_id, f, data, chan, send_res, persist, cache, options, sch_handle)
    @async begin
        try
            put!(chan, remotecall_fetch(do_task, p.pid, ctx, p, thunk_id,
                                        f, data, send_res, persist, cache,
                                        options, sch_handle))
        catch ex
            bt = catch_backtrace()
            put!(chan, (p, thunk_id, CapturedException(ex, bt)))
        end
        nothing
    end
end

end # module Sch
