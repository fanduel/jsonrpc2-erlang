defmodule JSONRPC2.Server.Handler do
  @moduledoc """
  A transport-agnostic server handler for JSON-RPC 2.0.

  ## Example

      defmodule SpecHandler do
        use JSONRPC2.Server.Handler

        def handle_request("subtract", [x, y]) do
          x - y
        end

        def handle_request("subtract", %{"minuend" => x, "subtrahend" => y}) do
          x - y
        end

        def handle_request("update", _) do
          :ok
        end

        def handle_request("sum", numbers) do
          Enum.sum(numbers)
        end

        def handle_request("get_data", []) do
          ["hello", 5]
        end
      end

      SpecHandler.handle(~s({"jsonrpc": "2.0", "method": "subtract", "params": [42, 23], "id": 1}))
      #=> ~s({"jsonrpc": "2.0", "result": 19, "id": 1})
  """

  require Logger

  @doc """
  Respond to a request for `method` with `params`.

  You can return any serializable result (which will be ignored for notifications), or you can throw
  these values to produce error responses:

    * `:method_not_found`, `:invalid_params`, `:internal_error`, `:server_error`
    * any of the above, in a tuple like `{:method_not_found, %{my_error_data: 1}}` to return extra
      data
    * `{:jsonrpc2, code, message}` or `{:jsonrpc2, code, message, data}` to return a custom error,
      with or without extra data.
  """
  @callback handle_request(method :: JSONRPC2.method(), params :: JSONRPC2.params()) ::
              JSONRPC2.json() | no_return

  defmacro __using__(_) do
    quote do
      @spec handle(String.t()) :: {:reply, String.t()} | :noreply
      def handle(json) do
        serializer = Application.get_env(:jsonrpc2, :serializer)

        unquote(__MODULE__).handle(__MODULE__, serializer, json)
      end
    end
  end

  @doc false
  def handle(module, serializer, json) when is_binary(json) do
    case serializer.decode(json) do
      {:ok, decoded_request} ->
        parse(decoded_request) |> collate_for_dispatch(module)

      {:error, _error} ->
        standard_error_response(:parse_error, nil)

      {:error, :invalid, _number} ->
        standard_error_response(:parse_error, nil)
    end
    |> encode_response(module, serializer, json)
  end

  def handle(module, serializer, json) do
    parse(json)
    |> collate_for_dispatch(module)
    |> encode_response(module, serializer, json)
  end

  defp collate_for_dispatch(batch_rpc, module) when is_list(batch_rpc) and length(batch_rpc) > 0 do
    merge_responses(Enum.map(batch_rpc, &dispatch(module, &1)))
  end

  defp collate_for_dispatch(rpc, module) do
    dispatch(module, rpc)
  end

  defp parse(requests) when is_list(requests) do
    for request <- requests, do: parse(request)
  end

  defp parse(request) when is_map(request) do
    version = Map.get(request, "jsonrpc", :undefined)
    method = Map.get(request, "method", :undefined)
    params = Map.get(request, "params", [])
    id = Map.get(request, "id", :undefined)

    if valid_request?(version, method, params, id) do
      {method, params, id}
    else
      :invalid_request
    end
  end

  defp parse(_) do
    :invalid_request
  end

  defp valid_request?(version, method, params, id) do
    version == "2.0" and is_binary(method) and (is_list(params) or is_map(params)) and
      (id in [:undefined, nil] or is_binary(id) or is_number(id))
  end

  defp merge_responses(responses) do
    case for({:reply, reply} <- responses, do: reply) do
      [] -> :noreply
      replies -> {:reply, replies}
    end
  end

  @throwable_errors [:method_not_found, :invalid_params, :internal_error, :server_error]

  defp dispatch(module, {method, params, id}) do
    try do
      result_response(module.handle_request(method, params), id)
    rescue
      e in FunctionClauseError ->
        # if that error originates from the very module.handle_request call - handle, otherwise - reraise
        case e do
          %FunctionClauseError{function: :handle_request, module: ^module} ->
            standard_error_response(:method_not_found, %{method: method, params: params}, id)

          other_e ->
            stacktrace = System.stacktrace()
            log_error(module, method, params, :error, other_e, stacktrace)
            Kernel.reraise(other_e, stacktrace)
        end
    catch
      :throw, error when error in @throwable_errors ->
        standard_error_response(error, id)

      :throw, {error, data} when error in @throwable_errors ->
        standard_error_response(error, data, id)

      :throw, {:jsonrpc2, code, message} when is_integer(code) and is_binary(message) ->
        error_response(code, message, id)

      :throw, {:jsonrpc2, code, message, data} when is_integer(code) and is_binary(message) ->
        error_response(code, message, data, id)

      kind, payload ->
        stacktrace = System.stacktrace()
        log_error(module, method, params, kind, payload, stacktrace)

        standard_error_response(:internal_error, id)
    end
  end

  defp dispatch(_module, _rpc) do
    standard_error_response(:invalid_request, nil)
  end

  defp log_error(module, method, params, kind, payload, stacktrace) do
    _ =
      Logger.error([
        "Error in handler ",
        inspect(module),
        " for method ",
        method,
        " with params: ",
        inspect(params),
        ":\n\n",
        Exception.format(kind, payload, stacktrace)
      ])
  end

  defp result_response(_result, :undefined) do
    :noreply
  end

  defp result_response(result, id) do
    {:reply,
     %{
       "jsonrpc" => "2.0",
       "result" => result,
       "id" => id
     }}
  end

  defp standard_error_response(error_type, id) do
    {code, message} = error_code_and_message(error_type)
    error_response(code, message, id)
  end

  defp standard_error_response(error_type, data, id) do
    {code, message} = error_code_and_message(error_type)
    error_response(code, message, data, id)
  end

  defp error_response(_code, _message, _data, :undefined) do
    :noreply
  end

  defp error_response(code, message, data, id) do
    {:reply, error_reply(code, message, data, id)}
  end

  defp error_response(_code, _message, :undefined) do
    :noreply
  end

  defp error_response(code, message, id) do
    {:reply, error_reply(code, message, id)}
  end

  defp error_reply(code, message, data, id) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => code,
        "message" => message,
        "data" => data
      },
      "id" => id
    }
  end

  defp error_reply(code, message, id) do
    %{
      "jsonrpc" => "2.0",
      "error" => %{
        "code" => code,
        "message" => message
      },
      "id" => id
    }
  end

  defp error_code_and_message(:parse_error), do: {-32700, "Parse error"}
  defp error_code_and_message(:invalid_request), do: {-32600, "Invalid Request"}
  defp error_code_and_message(:method_not_found), do: {-32601, "Method not found"}
  defp error_code_and_message(:invalid_params), do: {-32602, "Invalid params"}
  defp error_code_and_message(:internal_error), do: {-32603, "Internal error"}
  defp error_code_and_message(:server_error), do: {-32000, "Server error"}

  defp encode_response(:noreply, _module, _serializer, _json) do
    :noreply
  end

  defp encode_response({:reply, reply}, module, serializer, json) do
    case serializer.encode(reply) do
      {:ok, encoded_reply} ->
        {:reply, encoded_reply}

      {:error, reason} ->
        _ =
          Logger.info([
            "Handler ",
            inspect(module),
            " returned invalid reply:\n  Reason: ",
            inspect(reason),
            "\n  Received: ",
            inspect(reply),
            "\n  Request: ",
            json
          ])

        standard_error_response(:internal_error, nil)
        |> encode_response(module, serializer, json)
    end
  end
end
