defmodule Sige5Example.SecureKey.Server do
  @moduledoc """
  Holds one `optee-key serve` process open and talks to it.

  One helper, one TEE session, a line per request:

      > sign <hex digest>
      < ok <der hex>

  Owning the port here also keeps its exit signal away from the caller, which
  matters because `:ssl` calls the signing function inline in its connection
  process.

  Returns `:ignore` on a board with no secure world, so the same firmware runs
  on devices that have not been provisioned.
  """

  use GenServer

  require Logger

  @tool "/usr/bin/optee-key"
  @timeout 15_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Sign a digest. Returns the signature in DER."
  @spec sign(binary()) :: binary()
  def sign(digest) when is_binary(digest) do
    GenServer.call(__MODULE__, {:sign, Base.encode16(digest, case: :lower)}, @timeout)
  end

  @doc "The token's public key, as a DER SubjectPublicKeyInfo."
  @spec public_key() :: binary()
  def public_key, do: GenServer.call(__MODULE__, :pubkey, @timeout)

  @doc "Whether the helper is running."
  @spec available?() :: boolean()
  def available?, do: Process.whereis(__MODULE__) != nil

  @impl GenServer
  def init(opts) do
    token = Keyword.fetch!(opts, :token)
    pin = Keyword.fetch!(opts, :pin)
    key = Keyword.fetch!(opts, :key_label)

    cond do
      not File.exists?("/dev/tee0") ->
        Logger.info("[SecureKey] no /dev/tee0, secure world not present")
        :ignore

      not File.exists?(@tool) ->
        Logger.warning("[SecureKey] #{@tool} is missing")
        :ignore

      true ->
        # The PIN goes in the environment, not the arguments: this process
        # runs for the lifetime of the node, and /proc/<pid>/cmdline is
        # readable by anything on the system.
        port =
          Port.open({:spawn_executable, @tool}, [
            :binary,
            :exit_status,
            {:line, 4096},
            {:args, ["serve", token, key]},
            {:env, [{~c"OPTEE_KEY_PIN", String.to_charlist(pin)}]}
          ])

        {:ok, %{port: port}}
    end
  end

  @impl GenServer
  def handle_call({:sign, digest_hex}, _from, state) do
    {:reply, request(state.port, "sign #{digest_hex}"), state}
  end

  def handle_call(:pubkey, _from, state) do
    {:reply, request(state.port, "pubkey"), state}
  end

  @impl GenServer
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Let the supervisor restart it rather than limping on a dead helper
    {:stop, {:helper_exited, status}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp request(port, line) do
    Port.command(port, line <> "\n")

    receive do
      {^port, {:data, {:eol, "ok " <> hex}}} ->
        Base.decode16!(String.trim(hex), case: :lower)

      {^port, {:data, {:eol, "error " <> reason}}} ->
        raise "optee-key: #{reason}"
    after
      @timeout -> raise "optee-key did not answer within #{@timeout}ms"
    end
  end
end
