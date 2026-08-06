defmodule Sige5Example.TeeSupplicant do
  @moduledoc """
  Runs `tee-supplicant`, which the secure world needs in order to store
  anything.

  OP-TEE's default storage backend keeps its files in the normal world, under
  `/data/tee`, and reaches them through this daemon. Without it the secure
  world still boots and still holds the hardware unique key, but PKCS#11
  cannot persist an object - so a key can be generated and then vanishes.

  It is also what loads trusted applications from `/lib/optee_armtz`, the
  PKCS#11 TA among them.

  Supervised rather than started from the system image so that it restarts if
  it dies. A board with no secure world has no `/dev/tee0`, and this returns
  `:ignore` there instead of failing, so the same application runs on both.
  """

  require Logger

  @tee_device "/dev/tee0"
  @supplicant "/usr/sbin/tee-supplicant"

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent
    }
  end

  def start_link(_opts) do
    cond do
      not File.exists?(@tee_device) ->
        Logger.info("no #{@tee_device}, secure world not present - skipping tee-supplicant")
        :ignore

      not File.exists?(@supplicant) ->
        Logger.warning("#{@tee_device} exists but #{@supplicant} is missing")
        :ignore

      true ->
        Logger.info("starting tee-supplicant")
        MuonTrap.Daemon.start_link(@supplicant, [], name: __MODULE__, log_output: :debug)
    end
  end

  @doc """
  Whether the secure world is present and its storage is reachable.

  `/data/tee` only appears once something has been stored, so its absence is
  not a fault on a device that has not used secure storage yet.
  """
  def status do
    %{
      tee_device: File.exists?(@tee_device),
      supplicant_running: Process.whereis(__MODULE__) != nil,
      storage_dir: File.exists?("/data/tee")
    }
  end
end
