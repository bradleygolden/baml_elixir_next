defmodule BamlElixirTest.OpenAIHandler do
  @moduledoc false

  @type header_map :: %{optional(String.t()) => String.t()}

  @callback handle_request(path :: String.t(), headers :: header_map, body :: binary()) :: %{
              required(:status) => pos_integer(),
              optional(:headers) => [{String.t(), String.t()}],
              required(:body) => binary()
            }
end
