# Exclude integration tests by default (they require real API keys)
# Run with: mix test --include integration
ExUnit.start(exclude: [:integration])

Mox.defmock(BamlElixir.NativeMock, for: BamlElixir.NativeBehaviour)
