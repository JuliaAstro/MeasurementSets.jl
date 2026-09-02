# Cross-check the pure-Julia metadata reader against casacore (via Casacore.jl).
# Runs only when both the sample MS and Casacore.jl are available.

const _HAVE_CASACORE = try
    @eval import Casacore
    true
catch err
    @warn "Casacore.jl unavailable; skipping cross-check" err
    false
end

_scalar_eltype(::Type{T}) where {T} = T
_scalar_eltype(::Type{<:AbstractArray{T}}) where {T} = _scalar_eltype(T)

if _HAVE_CASACORE
    const CCT = Casacore.Tables

    _cc_eltype(tab, name) = _scalar_eltype(typeof(tab[Symbol(name)]).parameters[1])

    function crosscheck_table(ours::MSv2.CTDSTable, theirs)
        @test nrow(ours) == size(theirs, 1)
        @test Set(columnnames(ours)) == Set(String.(keys(theirs)))
        for c in ours.desc.columns
            MSv2.juliatype(c.type) === Nothing && continue   # records etc.
            @test MSv2.juliatype(c.type) == _cc_eltype(theirs, c.name)
        end
    end

    @testset "casacore cross-check" begin
        crosscheck_table(readtable(SAMPLE_MS), CCT.Table(SAMPLE_MS))

        main_cc = CCT.Table(SAMPLE_MS)
        @test Set(subtablenames(MeasurementSet(SAMPLE_MS))) ==
              Set(String.(propertynames(main_cc)))

        for sub in ("ANTENNA", "SPECTRAL_WINDOW", "POLARIZATION", "FIELD",
                    "FEED", "DATA_DESCRIPTION", "OBSERVATION", "SOURCE",
                    "STATE", "PROCESSOR")
            crosscheck_table(readtable(joinpath(SAMPLE_MS, sub)),
                             getproperty(main_cc, Symbol(sub)))
        end
    end
end
