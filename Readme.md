# macOS (Homebrew)
brew install juliaup
juliaup add release

# Linux / WSL (one-liner)
curl -fsSL https://install.julialang.org | sh
juliaup add release

julia -v

mkdir playwright_julia && cd playwright_julia

julia --project=. -e 'using Pkg;
  Pkg.activate(".");
  try Pkg.Registry.add("General") catch; end;
  Pkg.add(["Genie","HTTP","JSON"]);
  Pkg.precompile()'

julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'

`export MY_LLM_KEY="sk-123..."`

julia --project=. app.jl
# open http://127.0.0.1:8080