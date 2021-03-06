defmodule BertrpcEx.Worker do
  use GenServer.Behaviour
  require Lager

  defrecord ServerInfo, host: nil, port: 8080, socket: nil

  @timeout 5000

  def start_link(args) do
    :gen_server.start_link(__MODULE__, args, [])
  end

  def init(args) do
    try do
      server = build_server_info(args)
      {:ok, socket} = establish_connection(server)
      {:ok, server.socket(socket)}
    rescue
      ArgumentError -> {:stop, {:error, "Host and Port must be defined for each server"}}
    end
  end

  defp build_server_info(server) do
    if Enum.all?([:host, :port], Keyword.has_key?(server, &1)) do
      ServerInfo.new(port: server[:port], host: server[:host])
    else
      raise ArgumentError, message: "Server must define host and port"
    end
  end

  defp establish_connection(server_info) do
    Lager.info('Establishing connection to ~p on port ~p', [server_info.host, server_info.port])
    options = [
                :binary,
                {:packet, 4},
                {:active, false},
                {:send_timeout, @timeout},
                {:send_timeout_close, true}
              ]
    case :gen_tcp.connect(server_info.host, server_info.port, options) do
      {:ok, socket} -> {:ok, socket}
      error ->
        Lager.error('Unable to establish connection: ~p', [error])
        :timer.sleep(1000)
        establish_connection(server_info)
    end
  end

  def handle_call({module, func, args}, from, server_info) do
    socket = server_info.socket
    data = Bertex.encode({:call, module, func, args})
    case :gen_tcp.send(socket, data) do
      {:error, reason} ->
        Lager.error("Connection lost: #{reason}")
        retry_handle_call({module, func, args}, from, server_info)
      :ok ->
        reply = case :gen_tcp.recv(socket, 0, @timeout) do
          {:ok, recv_data} ->
            Lager.debug("Received data")
            case Bertex.decode(recv_data) do
              {:reply, result} ->
                Lager.debug("Received #{result}")
                {:reply, result, server_info}
              error -> Lager.error('Received unexpected data: ~p', [error])
                {:reply, {:error, error}, server_info}
            end
          {:error, :timeout} ->
            Lager.info("Timed out")
            {:reply, :error, server_info}
          {:error, :closed} ->
            Lager.info("TCP socket closed")
            retry_handle_call({module, func, args}, from, server_info)
          {:error, reason} ->
            Lager.error('Undefined error, reason: ~p',[reason])
            exit(reason)
        end
        reply
    end
  end
  def handle_call(_request, _from, state) do
    {:reply, :ok, state}
  end

  defp retry_handle_call(arguments, from, server_info) do
    {:ok, socket} = establish_connection(server_info)
    handle_call(arguments, from, server_info.socket(socket))
  end

  def handle_cast({module, func, args}, server_info) do
    data = Bertex.encode({:cast, module, func, args})
    case :gen_tcp.send(server_info.socket, data) do
      :ok -> :ok
      {:error, reason} -> Lager.error('Error while sending ~p, reason: ~p', [data, reason])
    end
    {:noreply, server_info}
  end

  def handle_cast({_msg, state}), do: {:noreply, state}

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, server_info) do
    :gen_tcp.close(server_info.socket)
  end

  def code_change(_, state, _), do: {:ok, state}

end
