# Aqua.jl quality checks (Phase 89).
#
# `Base.delete!` / `Base.insert!` are deliberately extended on
# `Union{AbstractString,AbstractTable}` (the `taql`-style write commands,
# Phases 30-31) -- a path string is a valid target -- so they are
# whitelisted for the type-piracy check.

import Aqua

@testset "Aqua" begin
    Aqua.test_all(MeasurementSets;
                  piracies = (treat_as_own = [Base.delete!, Base.insert!],))
end
