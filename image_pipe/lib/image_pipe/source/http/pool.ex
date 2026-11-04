defmodule ImagePipe.Source.HTTP.Pool do
  @moduledoc false

  # Given pool options, Req starts or finds their Finch instance through its
  # one DynamicSupervisor on every request, a call every origin request in the
  # VM would queue on. A pool started here once, under ImagePipe's supervisor,
  # is passed to Req by name instead. Req accepts only its build and request
  # options alongside a name.
  #
  # A Finch instance registers its name before it starts its pool supervisor,
  # so a registered name doesn't mean the instance is ready. The supervisor
  # returns from start_child, even with :already_started, only once the
  # instance has started, so the pid it returns is recorded, and a fetch calls
  # start_child again only when that instance has stopped.
  @pools ImagePipe.Source.HTTP.Pools
  @request_options [
    :pool_tag,
    :unix_socket,
    :pool_timeout,
    :receive_timeout,
    :request_timeout,
    :pool_strategy
  ]

  @doc false
  @spec named(keyword()) :: keyword()
  def named(finch) do
    {request_options, pool_options} = Keyword.split(finch, @request_options)
    name = pool_name(pool_options)

    case :persistent_term.get({@pools, name}, nil) do
      nil -> start_pool(name, pool_options)
      started -> unless Process.alive?(started), do: start_pool(name, pool_options)
    end

    [name: name] ++ request_options
  end

  defp start_pool(name, pool_options) do
    pid =
      case DynamicSupervisor.start_child(
             @pools,
             {Finch, name: name, pools: %{default: [start_pool_metrics?: true] ++ pool_options}}
           ) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    :persistent_term.put({@pools, name}, pid)
  end

  defp pool_name(pool_options) do
    hash =
      pool_options |> :erlang.term_to_binary() |> :erlang.md5() |> Base.encode32(padding: false)

    Module.concat(@pools, hash)
  end
end
