defmodule BamlElixir.NativeWrapper do
  @moduledoc """
  Wrapper around BamlElixir.Native that implements the NativeBehaviour.
  This allows the Native module to be mocked in tests.
  """

  @behaviour BamlElixir.NativeBehaviour

  defdelegate create_tripwire(), to: BamlElixir.Native
  defdelegate abort_tripwire(tripwire), to: BamlElixir.Native

  defdelegate stream(pid, ref, tripwire, function_name, args, path, collectors, registry, tb),
    to: BamlElixir.Native

  defdelegate call(function_name, args, path, collectors, registry, tb), to: BamlElixir.Native
end
