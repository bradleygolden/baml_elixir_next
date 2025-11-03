defmodule BamlElixirTest do
  use ExUnit.Case
  use BamlElixir.Client, path: "test/baml_src"

  alias BamlElixir.TypeBuilder

  doctest BamlElixir

  test "parses into a struct" do
    assert {:ok, %BamlElixirTest.Person{name: "John Doe", age: 28}} =
             BamlElixirTest.ExtractPerson.call(%{info: "John Doe, 28, Engineer"})
  end

  test "parsing into a struct with streaming" do
    pid = self()

    {:ok, _stream_pid} =
      BamlElixirTest.ExtractPerson.stream(%{info: "John Doe, 28, Engineer"}, fn result ->
        send(pid, result)
      end)

    messages = wait_for_all_messages()

    # assert more than 1 partial message
    assert Enum.filter(messages, fn {type, _} -> type == :partial end) |> length() > 1

    assert Enum.filter(messages, fn {type, _} -> type == :done end) == [
             {:done, %BamlElixirTest.Person{name: "John Doe", age: 28}}
           ]
  end

  test "parsing into a struct with sync_stream" do
    {:ok, agent_pid} = Agent.start_link(fn -> 0 end, name: :counter)

    assert {:ok, %BamlElixirTest.Person{name: "John Doe", age: 28}} =
             BamlElixirTest.ExtractPerson.sync_stream(
               %{info: "John Doe, 28, Engineer"},
               fn _result ->
                 Agent.update(agent_pid, fn count -> count + 1 end)
               end
             )

    assert Agent.get(agent_pid, fn count -> count end) > 1
  end

  test "bool input and output" do
    assert {:ok, true} = BamlElixirTest.FlipSwitch.call(%{switch: false})
  end

  test "parses into a struct with a type builder" do
    assert {:ok,
            %{
              __baml_class__: "NewEmployeeFullyDynamic",
              employee_id: _,
              person: %{
                name: "Foobar123",
                age: _,
                owned_houses_count: _,
                favorite_day: _,
                favorite_color: :RED,
                __baml_class__: "TestPerson"
              }
            }} =
             BamlElixirTest.CreateEmployee.call(%{}, %{
               tb: [
                 %TypeBuilder.Class{
                   name: "TestPerson",
                   fields: [
                     %TypeBuilder.Field{
                       name: "name",
                       type: :string,
                       description: "The name of the person - this should always be Foobar123"
                     },
                     %TypeBuilder.Field{name: "age", type: :int},
                     %TypeBuilder.Field{name: "owned_houses_count", type: 1},
                     %TypeBuilder.Field{
                       name: "favorite_day",
                       type: %TypeBuilder.Union{types: ["sunday", "monday"]}
                     },
                     %TypeBuilder.Field{
                       name: "favorite_color",
                       type: %TypeBuilder.Enum{name: "FavoriteColor"}
                     }
                   ]
                 },
                 %TypeBuilder.Enum{
                   name: "FavoriteColor",
                   values: [
                     %TypeBuilder.EnumValue{value: "RED", description: "Pick this always"},
                     %TypeBuilder.EnumValue{value: "GREEN"},
                     %TypeBuilder.EnumValue{value: "BLUE"}
                   ]
                 },
                 %TypeBuilder.Class{
                   name: "NewEmployeeFullyDynamic",
                   fields: [
                     %TypeBuilder.Field{
                       name: "person",
                       type: %TypeBuilder.Class{name: "TestPerson"}
                     }
                   ]
                 }
               ]
             })
  end

  test "parses type builder with nested types" do
    assert {:ok,
            %{
              __baml_class__: "NewEmployeeFullyDynamic",
              employee_id: _,
              person: %{
                __baml_class__: "ThisClassIsNotDefinedInTheBAMLFile",
                name: _,
                age: _,
                departments: list_of_deps,
                managers: list_of_managers,
                work_experience: work_exp_map
              }
            } = employee} =
             BamlElixirTest.CreateEmployee.call(%{}, %{
               tb: [
                 %TypeBuilder.Class{
                   name: "NewEmployeeFullyDynamic",
                   fields: [
                     %TypeBuilder.Field{
                       name: "person",
                       type: %TypeBuilder.Class{
                         name: "ThisClassIsNotDefinedInTheBAMLFile",
                         fields: [
                           %TypeBuilder.Field{name: "name", type: :string},
                           %TypeBuilder.Field{name: "age", type: :int},
                           %TypeBuilder.Field{
                             name: "departments",
                             type: %TypeBuilder.List{
                               type: %TypeBuilder.Class{
                                 name: "Department",
                                 fields: [
                                   %TypeBuilder.Field{name: "name", type: :string},
                                   %TypeBuilder.Field{name: "location", type: :string}
                                 ]
                               }
                             }
                           },
                           %TypeBuilder.Field{
                             name: "managers",
                             type: %TypeBuilder.List{type: :string}
                           },
                           %TypeBuilder.Field{
                             name: "work_experience",
                             type: %TypeBuilder.Map{
                               key_type: :string,
                               value_type: :string
                             }
                           }
                         ]
                       }
                     }
                   ]
                 }
               ]
             })

    assert Enum.sort(Map.keys(employee)) ==
             Enum.sort([:__baml_class__, :employee_id, :person])

    assert Enum.sort(Map.keys(employee.person)) ==
             Enum.sort([:__baml_class__, :name, :age, :departments, :managers, :work_experience])

    assert is_list(list_of_deps)
    assert is_list(list_of_managers)
    assert is_map(work_exp_map)
    assert Enum.all?(work_exp_map, fn {key, value} -> is_binary(key) and is_binary(value) end)
  end

  test "change default model" do
    assert {:ok, _} = BamlElixirTest.WhichModel.call(%{}, %{llm_client: "LocalQwen3"})
  end

  test "get union type" do
    assert {:ok, _} = BamlElixirTest.WhichModelUnion.call(%{}, %{llm_client: "LocalQwen3"})
  end

  test "Error when parsing the output of a function" do
    assert {:error, "Failed to coerce value" <> _} = BamlElixirTest.DummyOutputFunction.call(%{})
  end

  test "get usage from collector" do
    collector = BamlElixir.Collector.new("test-collector")

    assert {:ok, _} =
             BamlElixirTest.WhichModel.call(%{}, %{
               llm_client: "LocalQwen3",
               collectors: [collector]
             })

    usage = BamlElixir.Collector.usage(collector)
    assert usage["input_tokens"] > 0
    assert usage["output_tokens"] > 0
  end

  test "get usage from collector with streaming using LocalQwen3" do
    collector = BamlElixir.Collector.new("test-collector")
    pid = self()

    {:ok, _stream_pid} =
      BamlElixirTest.CreateEmployee.stream(
        %{},
        fn result -> send(pid, result) end,
        %{llm_client: "LocalQwen3", collectors: [collector]}
      )

    _messages = wait_for_all_messages()

    usage = BamlElixir.Collector.usage(collector)
    assert usage["input_tokens"] > 0
  end

  test "get last function log from collector" do
    collector = BamlElixir.Collector.new("test-collector")

    assert {:ok, _} =
             BamlElixirTest.WhichModel.call(%{}, %{
               llm_client: "LocalQwen3",
               collectors: [collector]
             })

    last_function_log = BamlElixir.Collector.last_function_log(collector)
    assert last_function_log["function_name"] == "WhichModel"

    assert Map.keys(last_function_log) == [
             "calls",
             "function_name",
             "id",
             "log_type",
             "raw_llm_response",
             "timing",
             "usage"
           ]
  end

  test "get last function log from collector with streaming" do
    collector = BamlElixir.Collector.new("test-collector")
    pid = self()

    {:ok, _stream_pid} =
      BamlElixirTest.CreateEmployee.stream(
        %{},
        fn result -> send(pid, result) end,
        %{llm_client: "LocalQwen3", collectors: [collector]}
      )

    _messages = wait_for_all_messages()

    last_function_log = BamlElixir.Collector.last_function_log(collector)

    %{"messages" => messages} =
      last_function_log["calls"]
      |> Enum.at(0)
      |> Map.get("request")
      |> Map.get("body")
      |> Jason.decode!()

    assert messages == [
             %{
               "content" => [
                 %{
                   "text" =>
                     "Create a fake employee data with the following information:\nAnswer in JSON using this schema:\n{\n  employee_id: string,\n}",
                   "type" => "text"
                 }
               ],
               "role" => "system"
             }
           ]
  end

  test "parsing of nested structs" do
    attendees = %BamlElixirTest.Attendees{
      hosts: [
        %BamlElixirTest.Person{name: "John Doe", age: 28},
        %BamlElixirTest.Person{name: "Bob Johnson", age: 35}
      ],
      guests: [
        %BamlElixirTest.Person{name: "Alice Smith", age: 25},
        %BamlElixirTest.Person{name: "Carol Brown", age: 30},
        %BamlElixirTest.Person{name: "Jane Doe", age: 28}
      ]
    }

    assert {:ok, attendees} ==
             BamlElixirTest.ParseAttendees.call(%{
               attendees: """
               John Doe 28 - Host
               Alice Smith 25 - Guest
               Bob Johnson 35 - Host
               Carol Brown 30 - Guest
               Jane Doe 28 - Guest
               """
             })
  end

  test "stream returns {:ok, pid}" do
    {:ok, stream_pid} =
      BamlElixirTest.ExtractPerson.stream(
        %{info: "John Doe, 28, Engineer"},
        fn _ -> :ok end
      )

    assert is_pid(stream_pid)
    assert Process.alive?(stream_pid)

    ref = Process.monitor(stream_pid)
    assert_receive {:DOWN, ^ref, :process, ^stream_pid, :normal}, 10_000
  end

  test "stream without cancellation completes normally" do
    pid = self()

    {:ok, stream_pid} =
      BamlElixirTest.ExtractPerson.stream(
        %{info: "John Doe, 28, Engineer"},
        fn result -> send(pid, result) end
      )

    assert is_pid(stream_pid)

    messages = wait_for_all_messages()

    done_messages = Enum.filter(messages, fn {type, _} -> type == :done end)
    assert length(done_messages) == 1

    assert [{:done, person}] = done_messages
    assert person.name == "John Doe"
    assert person.age == 28

    assert {:ok, :completed} = BamlElixir.Stream.await(stream_pid, 1000)
    refute Process.alive?(stream_pid)
  end

  test "cancelling stream via BamlElixir.Stream.cancel/1" do
    pid = self()

    {:ok, stream_pid} =
      BamlElixirTest.ExtractPerson.stream(
        %{info: "John Doe, 28, Engineer"},
        fn result -> send(pid, result) end
      )

    ref = Process.monitor(stream_pid)
    assert :ok = BamlElixir.Stream.cancel(stream_pid)
    assert_receive {:DOWN, ^ref, :process, ^stream_pid, :shutdown}, 5000

    refute Process.alive?(stream_pid)
  end

  test "cancelling stream via Process.exit/2" do
    pid = self()

    {:ok, stream_pid} =
      BamlElixirTest.ExtractPerson.stream(
        %{info: "John Doe, 28, Engineer"},
        fn result -> send(pid, result) end
      )

    ref = Process.monitor(stream_pid)
    Process.exit(stream_pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^stream_pid, :shutdown}, 1000
    refute Process.alive?(stream_pid)
  end

  test "BamlElixir.Stream.await/2 waits for completion" do
    pid = self()

    {:ok, stream_pid} =
      BamlElixirTest.ExtractPerson.stream(
        %{info: "John Doe, 28, Engineer"},
        fn result -> send(pid, result) end
      )

    assert {:ok, :completed} = BamlElixir.Stream.await(stream_pid, 10_000)
    refute Process.alive?(stream_pid)
  end

  test "BamlElixir.Stream.await/2 detects cancellation" do
    pid = self()

    {:ok, stream_pid} =
      BamlElixirTest.ExtractPerson.stream(
        %{info: "John Doe, 28, Engineer"},
        fn result -> send(pid, result) end
      )

    ref = Process.monitor(stream_pid)
    BamlElixir.Stream.cancel(stream_pid)
    assert_receive {:DOWN, ^ref, :process, ^stream_pid, :shutdown}, 5000

    result = BamlElixir.Stream.await(stream_pid, 1000)
    assert {:error, :noproc} = result
    refute Process.alive?(stream_pid)
  end

  defp wait_for_all_messages(messages \\ []) do
    receive do
      {:partial, _} = message ->
        wait_for_all_messages([message | messages])

      {:done, _} = message ->
        [message | messages] |> Enum.reverse()

      {:error, message} ->
        raise "Error: #{inspect(message)}"
    end
  end
end
