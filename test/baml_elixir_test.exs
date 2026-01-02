defmodule BamlElixirTest do
  use ExUnit.Case
  use BamlElixir.Client, path: "test/baml_src"

  import Mox

  alias BamlElixir.TypeBuilder

  doctest BamlElixir

  setup :set_mox_from_context
  setup :verify_on_exit!

  @tag :client_registry
  test "client_registry supports clients key (list form)" do
    client_registry = %{
      primary: "InjectedClient",
      clients: [
        %{
          name: "InjectedClient",
          provider: "definitely-not-a-provider",
          retry_policy: nil,
          options: %{model: "gpt-4o-mini"}
        }
      ]
    }

    # parse: false to avoid any parsing work; we want to exercise registry decoding/validation
    assert {:error, msg} =
             BamlElixirTest.WhichModel.call(%{}, %{client_registry: client_registry, parse: false})

    assert msg =~ "Invalid client provider"
  end

  @tag :client_registry
  test "client_registry supports clients key (map form)" do
    client_registry = %{
      primary: "InjectedClient",
      clients: %{
        "InjectedClient" => %{
          provider: "definitely-not-a-provider",
          retry_policy: nil,
          options: %{model: "gpt-4o-mini"}
        }
      }
    }

    assert {:error, msg} =
             BamlElixirTest.WhichModel.call(%{}, %{client_registry: client_registry, parse: false})

    assert msg =~ "Invalid client provider"
  end

  @tag :client_registry
  test "client_registry can inject and select a client not present in the BAML files (success path)" do
    BamlElixirTest.FakeOpenAIServer.expect_chat_completion("GPT")
    base_url = BamlElixirTest.FakeOpenAIServer.start_base_url()

    client_registry = %{
      primary: "InjectedClient",
      clients: [
        %{
          name: "InjectedClient",
          provider: "openai-generic",
          retry_policy: nil,
          options: %{
            base_url: base_url,
            api_key: "test-key",
            model: "gpt-4o-mini"
          }
        }
      ]
    }

    # This function declares `client GPT4` in the .baml file, so success here proves
    # `client_registry.primary` overrides the static client selection.
    assert {:ok, "GPT"} =
             BamlElixirTest.WhichModelUnion.call(%{}, %{client_registry: client_registry})
  end

  @tag :client_registry
  test "client_registry passes clients[].options.headers into the HTTP request" do
    BamlElixirTest.FakeOpenAIServer.expect_chat_completion("GPT", %{
      "x-test-header" => "hello-from-elixir"
    })

    base_url = BamlElixirTest.FakeOpenAIServer.start_base_url()

    client_registry = %{
      primary: "InjectedClient",
      clients: [
        %{
          name: "InjectedClient",
          provider: "openai-generic",
          retry_policy: nil,
          options: %{
            base_url: base_url,
            api_key: "test-key",
            model: "gpt-4o-mini",
            headers: %{
              "x-test-header" => "hello-from-elixir"
            }
          }
        }
      ]
    }

    assert {:ok, "GPT"} =
             BamlElixirTest.WhichModelUnion.call(%{}, %{client_registry: client_registry})
  end

  test "parses into a struct" do
    assert {:ok, %BamlElixirTest.Person{name: "John Doe", age: 28}} =
             BamlElixirTest.ExtractPerson.call(%{info: "John Doe, 28, Engineer"})
  end

  test "parsing into a struct with streaming" do
    pid = self()

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
    assert BamlElixirTest.WhichModel.call(%{}, %{llm_client: "GPT4"}) == {:ok, :GPT4oMini}
    assert BamlElixirTest.WhichModel.call(%{}, %{llm_client: "DeepSeekR1"}) == {:ok, :DeepSeekR1}
  end

  test "get union type" do
    assert BamlElixirTest.WhichModelUnion.call(%{}, %{llm_client: "GPT4"}) == {:ok, "GPT"}

    assert BamlElixirTest.WhichModelUnion.call(%{}, %{llm_client: "DeepSeekR1"}) ==
             {:ok, "DeepSeek"}
  end

  test "Error when parsing the output of a function" do
    assert {:error, "Failed to coerce value" <> _} = BamlElixirTest.DummyOutputFunction.call(%{})
  end

  test "get usage from collector" do
    collector = BamlElixir.Collector.new("test-collector")

    assert BamlElixirTest.WhichModel.call(%{}, %{llm_client: "GPT4", collectors: [collector]}) ==
             {:ok, :GPT4oMini}

    usage = BamlElixir.Collector.usage(collector)
    assert usage["input_tokens"] == 33
    assert usage["output_tokens"] > 0
  end

  test "get usage from collector with streaming using GPT4" do
    collector = BamlElixir.Collector.new("test-collector")
    pid = self()

    BamlElixirTest.CreateEmployee.stream(
      %{},
      fn result -> send(pid, result) end,
      %{llm_client: "GPT4", collectors: [collector]}
    )

    _messages = wait_for_all_messages()

    usage = BamlElixir.Collector.usage(collector)
    assert usage["input_tokens"] == 32
  end

  test "get last function log from collector" do
    collector = BamlElixir.Collector.new("test-collector")

    assert BamlElixirTest.WhichModel.call(%{}, %{llm_client: "GPT4", collectors: [collector]}) ==
             {:ok, :GPT4oMini}

    last_function_log = BamlElixir.Collector.last_function_log(collector)
    assert last_function_log["function_name"] == "WhichModel"

    response_body =
      last_function_log["calls"]
      |> Enum.at(0)
      |> Map.get("response")
      |> Map.get("body")
      |> Jason.decode!()

    assert response_body["usage"]["prompt_tokens_details"] == %{
             "audio_tokens" => 0,
             "cached_tokens" => 0
           }

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

    BamlElixirTest.CreateEmployee.stream(
      %{},
      fn result -> send(pid, result) end,
      %{llm_client: "GPT4", collectors: [collector]}
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

  describe "stream cancellation" do
    @tag :stream_cancellation
    test "killing caller process aborts the stream" do
      test_pid = self()
      {:ok, port} = start_streaming_server(test_pid)
      base_url = "http://127.0.0.1:#{port}/v1"

      client_registry = %{
        primary: "StreamingClient",
        clients: [
          %{
            name: "StreamingClient",
            provider: "openai-generic",
            retry_policy: nil,
            options: %{
              base_url: base_url,
              api_key: "test-key",
              model: "gpt-4o-mini"
            }
          }
        ]
      }

      caller_pid =
        spawn(fn ->
          BamlElixirTest.WhichModelUnion.stream(
            %{},
            fn result -> send(test_pid, {:stream_result, result}) end,
            %{client_registry: client_registry}
          )

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:stream_result, {:partial, _}}, 5_000
      _chunks_before_kill = count_chunks_received()

      Process.exit(caller_pid, :kill)
      Process.sleep(200)

      chunks_after_wait = count_chunks_received()

      assert chunks_after_wait < 15,
             "Expected stream to be cancelled but received #{chunks_after_wait} chunks"

      refute_receive {:stream_result, {:done, _}}, 500
    end

    defp start_streaming_server(test_pid) do
      {:ok, listen_socket} =
        :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

      {:ok, port} = :inet.port(listen_socket)

      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _data} = recv_until_headers(socket, <<>>)

        headers =
          "HTTP/1.1 200 OK\r\n" <>
            "content-type: text/event-stream\r\n" <>
            "transfer-encoding: chunked\r\n" <>
            "\r\n"

        :gen_tcp.send(socket, headers)

        for i <- 0..19 do
          chunk =
            Jason.encode!(%{
              "id" => "chatcmpl-test",
              "object" => "chat.completion.chunk",
              "created" => 1_700_000_000,
              "model" => "gpt-4o-mini",
              "system_fingerprint" => "fp_test",
              "choices" => [
                %{
                  "index" => 0,
                  "delta" => %{"content" => "\"GPT\""},
                  "logprobs" => nil,
                  "finish_reason" => nil
                }
              ]
            })

          sse_data = "data: #{chunk}\n\n"
          http_chunk = "#{Integer.to_string(byte_size(sse_data), 16)}\r\n#{sse_data}\r\n"

          case :gen_tcp.send(socket, http_chunk) do
            :ok ->
              send(test_pid, {:chunk_sent, i})
              Process.sleep(100)

            {:error, _} ->
              :ok
          end
        end

        done_data = "data: [DONE]\n\n"
        done_chunk = "#{Integer.to_string(byte_size(done_data), 16)}\r\n#{done_data}\r\n"
        :gen_tcp.send(socket, done_chunk)
        :gen_tcp.send(socket, "0\r\n\r\n")
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

      {:ok, port}
    end

    defp recv_until_headers(socket, acc) do
      case :binary.match(acc, "\r\n\r\n") do
        {_, _} ->
          {:ok, acc}

        :nomatch ->
          case :gen_tcp.recv(socket, 0, 5000) do
            {:ok, chunk} -> recv_until_headers(socket, acc <> chunk)
            other -> other
          end
      end
    end

    defp count_chunks_received(count \\ 0) do
      receive do
        {:chunk_sent, _} -> count_chunks_received(count + 1)
      after
        0 -> count
      end
    end
  end
end
