defmodule Sige5Example.FirmwareValidator do
  @moduledoc """
  Validates the running firmware once the device reaches the internet.

  Newly installed firmware boots with `nerves_fw_validated=0`. If nothing
  sets it to 1, the bootloader boots the previous slot on the next reboot
  (once this system's U-Boot is in the SPI NOR). Validating on internet
  connectivity means a firmware that boots but can never get online is
  automatically rolled back instead of being stranded.

  That last part only works if something eventually reboots a device that
  never gets online, which is what the `:heart` callback here is for. This
  stands in for `Nerves.Runtime.StartupGuard` and is modelled on it: the
  stock guard validates once the release's applications are up, and this
  one holds out for connectivity instead. `startup_guard_enabled` is
  therefore false in `config/target.exs` - running both would be pointless,
  since the stock guard would validate on "apps started" long before
  connectivity was ever proven.

  The order matters. The callback is installed first, then
  `Heart.init_complete/0` acknowledges the initialization handshake, and the
  callback is cleared only after validation actually succeeds. Acknowledging
  the handshake without arming the callback would disable
  `HEART_INIT_TIMEOUT` while putting nothing in its place, leaving a device
  that never connects running unvalidated forever with nothing to trigger
  the reboot the rollback depends on.
  """
  use GenServer, restart: :transient

  require Logger

  # Reboot at the 15 minute mark if the firmware is still unvalidated.
  @give_up_minutes 15

  # Start complaining after 2 minutes.
  @start_warning_minutes 2

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    # Arm the time bomb before acknowledging the handshake, never after.
    :ok = :heart.set_callback(__MODULE__, :heart_check)
    Nerves.Runtime.Heart.init_complete()

    case Nerves.Runtime.firmware_validation_status() do
      :validated ->
        :heart.clear_callback()
        :ignore

      _unvalidated_or_unknown ->
        VintageNet.subscribe(["connection"])
        {:ok, :waiting, {:continue, :check}}
    end
  end

  @impl true
  def handle_continue(:check, state) do
    maybe_validate(VintageNet.get(["connection"]), state)
  end

  @impl true
  def handle_info({VintageNet, ["connection"], _old, status, _meta}, state) do
    maybe_validate(status, state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_validate(:internet, state) do
    case Nerves.Runtime.validate_firmware() do
      :ok ->
        Logger.info("Firmware validated: internet connectivity confirmed")
        :heart.clear_callback()
        {:stop, :normal, state}

      other ->
        # Leave the callback armed: firmware that cannot be validated is
        # exactly what the reboot-and-revert path exists for.
        Logger.error("Firmware validation failed: #{inspect(other)}")
        {:noreply, state}
    end
  end

  defp maybe_validate(_not_internet, state), do: {:noreply, state}

  @doc false
  @spec heart_check() :: :ok | :error
  def heart_check, do: do_heart_check(uptime_minutes())

  @doc false
  @spec do_heart_check(non_neg_integer()) :: :ok | :error
  def do_heart_check(uptime_minutes) do
    cond do
      uptime_minutes >= @give_up_minutes ->
        Logger.error(
          "Firmware never validated - no internet in #{uptime_minutes} min. Rebooting."
        )

        :error

      uptime_minutes >= @start_warning_minutes ->
        Logger.warning(
          "Firmware still unvalidated after #{uptime_minutes} min; " <>
            "rebooting to roll back at #{@give_up_minutes} min"
        )

        :ok

      true ->
        :ok
    end
  end

  defp uptime_minutes do
    {seconds, _} = File.read!("/proc/uptime") |> String.split(" ") |> hd() |> Float.parse()

    trunc(seconds / 60)
  end
end
