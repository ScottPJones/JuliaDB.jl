import Dagger: Domain, chunktype, domain, tochunk,
               chunks, compute, gather


# re-export the essentials
export distribute, chunks, compute, gather

const IndexTuple = Union{Tuple, NamedTuple}

immutable DTable{K,V,I} # T<:Table
    index_space::I
    chunks::Table
end

function DTable{K,V,I}(::Type{K}, ::Type{V}, index_space::I, cs)
    DTable{K,V,I}(index_space, cs)
end

chunks(dt::DTable) = dt.chunks

"""
Compute any delayed-evaluation in the distributed table.

The computed data is left on the worker processes.

The first ctx is an optional Dagger.Context object
enumerating processes where any unevaluated chunks must be computed

TODO: Spill to disk
"""
function compute(ctx, t::DTable)
    chunkcol = chunks(t).data.columns.chunk
    if any(Dagger.istask, chunkcol)
        # we need to splat `thunks` so that Dagger knows the inputs
        # are thunks and they need to be staged for scheduling
        vec_thunk = delayed((refs...) -> [refs...]; meta=true)(chunkcol...)
        cs = compute(ctx, vec_thunk) # returns a vector of Chunk objects
        fromchunks(cs)
    else
        t
    end
end

"""
Gather data in a DTable into an Table object

The first ctx is an optional Dagger.Context object
enumerating processes where any unevaluated chunks must be computed
"""
function gather{T}(ctx, dt::DTable{T})
    cs = chunks(dt).data.columns.chunk
    if length(cs) > 0
        gather(ctx, treereduce(delayed(_merge), cs))
    else
        error("Empty table")
    end
end

# Fast-path merge if the data don't overlap
function _merge(a, b)
    if isempty(a)
        b
    elseif isempty(b)
        a
    elseif last(a.index) < first(b.index)
        # can hcat
        Table(vcat(a.index, b.index), vcat(a.data, b.data))
    elseif last(b.index) < first(a.index)
        _merge(b, a)
    else
        merge(a, b)
    end
end

"""
`mapchunks(f, nds::Table; keeplengths=true)`

Delayed application of a function to each chunk in an DTable.
Returns a new DTable. if `keeplength` is false, the output
lengths will all be `Nullable{Int}()`
"""
function mapchunks(f, dt::DTable; keeplengths=true)
    withchunksindex(dt) do cs
        mapchunks(f, cs, keeplengths=keeplengths)
    end
end

"""
`IndexSpace(interval, boundingrect, nrows)`

metadata about an Table chunk. When storing metadata about a chunk we must be
conservative about what we store. i.e. it is ok to store that a chunk has more
indices than what it actually contains.

- `interval`: An `Interval` object with the first and the last index tuples.
- `boundingrect`: An `Interval` object with the lowest and the highest indices as tuples.
- `nrows`: A `Nullable{Int}` of number of rows in the Table, if knowable
           (See design doc section on "Knowability of chunk size")
"""
immutable IndexSpace{T<:IndexTuple}
    interval::Interval{T}
    boundingrect::Interval{T}
    nrows::Nullable{Int}
end

immutable EmptySpace{T} <: Domain end

# Teach dagger how to automatically figure out the
# metadata (in dagger parlance "domain") about an Table chunk.
function Dagger.domain(nd::Table)
    if isempty(nd)
        return EmptySpace{eltype(nd.index)}()
    end

    interval = Interval(first(nd.index), last(nd.index))
    cs = astuple(nd.index.columns)
    extr = map(extrema, cs)
    boundingrect = Interval(map(first, extr), map(last, extr))
    return IndexSpace(interval, boundingrect, Nullable{Int}(length(nd)))
end

Base.eltype{T}(::IndexSpace{T}) = T
Base.eltype{T}(::EmptySpace{T}) = T

Base.isempty(::EmptySpace) = true
Base.isempty(::IndexSpace) = false

nrows(td::IndexSpace) = td.nrows
nrows(td::EmptySpace) = Nullable(0)

Base.ndims{T}(::IndexSpace{T})  = nfields(T)
Base.ndims{T}(::EmptySpace{T})  = nfields(T)

Base.first(td::IndexSpace) = first(td.interval)
Base.last(td::IndexSpace) = last(td.interval)

mins(td::IndexSpace) = first(td.boundingrect)
maxes(td::IndexSpace) = last(td.boundingrect)

function Base.merge(d1::IndexSpace, d2::IndexSpace, collisions=true)
    n = collisions || isnull(d1.nrows) || isnull(d2.nrows) ?
        Nullable{Int}() :
        Nullable(get(d1.nrows) + get(d2.nrows))

    interval = merge(d1.interval, d2.interval)
    boundingrect = merge(d1.boundingrect, d2.boundingrect)
    IndexSpace(interval, boundingrect, n)
end
Base.merge(d1::IndexSpace, d2::EmptySpace) = d1
Base.merge(d1::EmptySpace, d2::Union{IndexSpace, EmptySpace}) = d2

function Base.intersect(d1::IndexSpace, d2::IndexSpace)
    interval = intersect(d1.interval, d2.interval)
    boundingrect = intersect(d1.boundingrect, d2.boundingrect)
    IndexSpace(interval, boundingrect, Nullable{Int}())
end

function Base.intersect(d1::EmptySpace, d2::Union{IndexSpace,EmptySpace})
    d1
end

"""
`chunks_index(subdomains, chunks)`

- `subdomains`: a vector of subdomains
- `chunks`: a vector of chunks for those corresponding subdomains

Create an lookup table from a bunch of `IndexSpace`s
This lookup table is itself an Table object indexed by the
first and last indices in the chunks. We enforce the constraint
that the chunks must be disjoint to make such an arrangement
possible. But this is kind of silly though since all the lookups
are best done on the bounding boxes. So,
TODO: use an RTree of bounding boxes here.
"""
function chunks_index(subdomains, chunks)

    index = Columns(map(x->Array{Interval{typeof(x)}}(0),
                        first(subdomains[1].interval))...)
    boundingrects = Columns(map(x->Array{Interval{typeof(x)}}(0),
                             first(subdomains[1].boundingrect))...)

    for subd in subdomains
        push!(index, map(Interval, first(subd), last(subd)))
        push!(boundingrects, map(Interval, mins(subd), maxes(subd)))
    end

    Table(index, Columns(boundingrects,
                            chunks, map(x->x.nrows, subdomains),
                            names=[:boundingrect, :chunk, :length]))
end

# given a chunks index constructed above, give an array of
# index spaces spanned by the chunks in the index
function index_spaces(t::Table)
    intervals = map(x-> Interval(map(first, x), map(last, x)), t.index)
    boundingrects = map(x-> Interval(map(first, x), map(last, x)), t.data.columns.boundingrect)
    map(IndexSpace, intervals, boundingrects, t.data.columns.length)
end

function trylength(t::DTable)
    len = Nullable(0)
    for l in chunks(t).data.columns.length
        if !isnull(l) && !isnull(len)
            len = Nullable(get(len) + get(l))
        else
            return Nullable{Int}()
        end
    end
    return len
end

function Base.length(t::DTable)
    l = trylength(t)
    if isnull(l)
        error("The length of the DTable is not yet known since some of its parts are not yet computed. Call `compute` to compute them, and then call `length` on the result of `compute`.")
    else
        get(l)
    end
end

"""
`fromchunks(chunks::AbstractArray)`

Convenience function to create a DTable from an array of chunks.
The chunks must be non-Thunks. Omits empty chunks in the output.
"""
function fromchunks(chunks::AbstractArray)

    subdomains = map(domain, chunks)
    nzidxs = find(x->!isempty(x), subdomains)
    subdomains = subdomains[nzidxs]
    kvtypes = getkvtypes.(chunktype.(chunks))
    K, V = kvtypes[1]
    for (Tk, Tv) in kvtypes[2:end]
        K = promote_type(Tk, K)
        V = promote_type(Tv, V)
    end

    idxs = reduce(merge, subdomains)
    DTable(K, V, idxs,
           chunks_index(subdomains, chunks[nzidxs]))
end

function getkvtypes{N<:Table}(::Type{N})
    N.parameters[2], N.parameters[1]
end

### Distribute a Table into a DTable

"""
`distribute(nds::Table, rowgroups::AbstractArray)`

Distribute an Table object into chunks of number of
rows specified by `rowgroups`. `rowgroups` is a vector specifying the number of
rows in the respective chunk.

Returns a `DTable`.
"""
function distribute(nds::Table, rowgroups::AbstractArray)
    splits = cumsum([0, rowgroups;])

    if splits[end] != length(nds)
        throw(ArgumentError("the row groups don't add up to total number of rows"))
    end

    ranges = map(UnitRange, splits[1:end-1].+1, splits[2:end])

    chunks = map(r->tochunk(subtable(nds, r)), ranges)
    fromchunks(chunks)
end

"""
`distribute(nds::Table, nchunks::Int=nworkers())`

Distribute an NDSpase object into `nchunks` chunks of equal size.

Returns a `DTable`.
"""
function distribute(nds::Table, nchunks=nworkers())
    N = length(nds)
    q, r = divrem(N, nchunks)
    nrows = vcat(collect(_repeated(q, nchunks)))
    nrows[end] += r
    distribute(nds, nrows)
end

# DTable utilities
function subdomain(nds, r)
    # TODO: speed it up
    domain(subtable(nds, r))
end

function withchunksindex{K,V}(f, dt::DTable{K,V})
    cs = f(chunks(dt))
    DTable(K, V, dt.index_space, cs)
end

"""
`mapchunks(f, nds::Table; keeplengths=true)`

Apply a function to the chunk objects in an index.
Returns an Table. if `keeplength` is false, the output
lengths will all be Nullable{Int}
"""
function mapchunks(f, nds::Table; keeplengths=true)
    cols = nds.data.columns
    outchunks = map(f, cols.chunk)
    outlengths = keeplengths ? cols.length : fill(Nullable{Int}(), length(cols.length))
    Table(nds.index,
          Columns(cols.boundingrect,
                  outchunks, outlengths,
                  names=[:boundingrect, :chunk, :length]))
end

