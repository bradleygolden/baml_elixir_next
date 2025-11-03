defmodule BamlElixir.Stream do
  @moduledoc """
  GenServer that manages a BAML streaming operation.

  This process holds the TripWire resource internally and coordinates cancellation
  between Elixir processes and the Rust NIF layer.

  ## Usage

      # Start a stream
      {:ok, stream_pid} = BamlElixir.Stream.start_link(
        "ExtractPerson",
        %{info: "John Doe, 28"},
        fn result -> IO.inspect(result) end
      )

      # Cancel the stream
      BamlElixir.Stream.cancel(stream_pid)

      # Or use Process.exit directly
      Process.exit(stream_pid, :shutdown)

      # Wait for completion
      {:ok, :completed} = BamlElixir.Stream.await(stream_pid, 5000)
  """

  use GenServer

  defmodule State do
    @moduledoc false
    defstruct [
      :tripwire,
      :function_name,
      :args,
      :callback,
      :opts,
      :stream_pid,
      :stream_ref,
      :result_ref
    ]
  end

  ## Public API

  @doc """
  Starts a new streaming operation.

  Returns `{:ok, pid}` where the pid can be used to cancel the stream.

  ## Parameters
    - `function_name`: The name of the BAML function to stream
    - `args`: A map of arguments to pass to the function
    - `callback`: A function that will be called with streaming results
    - `opts`: A map of options (path, collectors, llm_client, etc.)

  ## Returns
    - `{:ok, pid}` on success
    - `{:error, reason}` on failure
  """
  @spec start_link(String.t(), map(), function(), map()) :: {:ok, pid()} | {:error, term()}
  def start_link(function_name, args, callback, opts \\ %{}) do
    GenServer.start_link(__MODULE__, {function_name, args, callback, opts})
  end

  @doc """
  Cancels a running stream.

  This triggers the Rust TripWire and stops the streaming operation gracefully.

  ## Parameters
    - `pid`: The PID of the stream process
    - `reason`: The reason for cancellation (default: `:cancelled`)

  ## Returns
    - `:ok`
  """
  @spec cancel(pid(), term()) :: :ok
  def cancel(pid, reason \\ :cancelled) do
    GenServer.call(pid, {:cancel, reason})
  end

  @doc """
  Waits for a stream to complete.

  ## Parameters
    - `pid`: The PID of the stream process
    - `timeout`: Timeout in milliseconds (default: 5000)

  ## Returns
    - `{:ok, :completed}` if the stream finished normally
    - `{:ok, :cancelled}` if the stream was cancelled
    - `{:error, reason}` if the stream failed
    - `{:error, :timeout}` if the timeout was reached
  """
  @spec await(pid(), timeout()) ::
          {:ok, :completed} | {:ok, :cancelled} | {:error, term()}
  def await(pid, timeout \\ 5000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        {:ok, :completed}

      {:DOWN, ^ref, :process, ^pid, :cancelled} ->
        {:ok, :cancelled}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  ## GenServer Callbacks

  @impl true
  def init({function_name, args, callback, opts}) do
    # Create TripWire on GenServer initialization
    tripwire = BamlElixir.Native.create_tripwire()

    state = %State{
      tripwire: tripwire,
      function_name: function_name,
      args: args,
      callback: callback,
      opts: opts
    }

    # Start streaming immediately
    {:ok, state, {:continue, :start_stream}}
  end

  @impl true
  def handle_continue(:start_stream, state) do
    result_ref = make_ref()
    stream_ref = make_ref()

    # Spawn the streaming work
    stream_pid =
      spawn_link(fn ->
        start_nif_stream(
          self(),
          result_ref,
          stream_ref,
          state.tripwire,
          state.function_name,
          state.args,
          state.opts
        )

        handle_stream_results(result_ref, state.callback, state.opts)
      end)

    {:noreply, %{state | stream_pid: stream_pid, stream_ref: stream_ref, result_ref: result_ref}}
  end

  @impl true
  def handle_call({:cancel, reason}, _from, state) do
    # Abort the TripWire
    BamlElixir.Native.abort_tripwire(state.tripwire)

    # Stop the GenServer with the specified reason
    {:stop, reason, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{stream_pid: pid} = state) do
    # Stream process died - shut down GenServer
    {:stop, reason, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Ensure TripWire is aborted on termination
    if state.tripwire do
      BamlElixir.Native.abort_tripwire(state.tripwire)
    end

    :ok
  end

  ## Private Functions

  # Spawns the NIF stream process
  defp start_nif_stream(parent_pid, result_ref, stream_ref, tripwire, function_name, args, opts) do
    {path, collectors, client_registry, tb} = prepare_opts(opts)

    # Spawn a linked process to call the NIF
    spawn_link(fn ->
      result =
        BamlElixir.Native.stream(
          parent_pid,
          result_ref,
          tripwire,
          function_name,
          args,
          path,
          collectors,
          client_registry,
          tb
        )

      # Send completion signal
      send(parent_pid, {stream_ref, result})
    end)
  end

  # Recursively handles streaming results
  defp handle_stream_results(ref, callback, opts) do
    receive do
      {^ref, {:partial, result}} ->
        result =
          if opts[:parse] != false do
            parse_result(result, opts[:prefix], opts[:tb])
          else
            result
          end

        callback.({:partial, result})
        handle_stream_results(ref, callback, opts)

      {^ref, {:error, _} = msg} ->
        callback.(msg)

      {^ref, {:done, result}} ->
        result =
          if opts[:parse] != false do
            parse_result(result, opts[:prefix], opts[:tb])
          else
            result
          end

        callback.({:done, result})
    end
  end

  # Prepares options for the NIF call
  defp prepare_opts(opts) do
    path = opts[:path] || "baml_src"
    collectors = (opts[:collectors] || []) |> Enum.map(fn collector -> collector.reference end)
    client_registry = opts[:llm_client] && %{primary: opts[:llm_client]}
    {path, collectors, client_registry, opts[:tb]}
  end

  # Parse result based on type builder or prefix
  defp parse_result(%{:__baml_class__ => _class_name} = result, prefix, tb)
       when not is_nil(tb) do
    Map.new(result, fn {key, value} -> {key, parse_result(value, prefix, tb)} end)
  end

  defp parse_result(%{:__baml_class__ => class_name} = result, prefix, tb) do
    module = Module.concat(prefix, class_name)
    values = Enum.map(result, fn {key, value} -> {key, parse_result(value, prefix, tb)} end)
    struct(module, values)
  end

  defp parse_result(%{:__baml_enum__ => _, :value => value}, _prefix, _tb) do
    String.to_atom(value)
  end

  defp parse_result(list, prefix, tb) when is_list(list) do
    Enum.map(list, fn item -> parse_result(item, prefix, tb) end)
  end

  defp parse_result(result, _prefix, _tb) do
    result
  end
end
