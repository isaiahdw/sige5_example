defmodule Sige5Example do
  @moduledoc """
  Sige5 bring-up checks. From the IEx console (serial or ssh):

      Sige5Example.check()

  prints a pass/fail line per subsystem.
  """

  @checks [
    {"watchdog", "/dev/watchdog0 exists (nerves_heart)", &__MODULE__.file?/1, "/dev/watchdog0"},
    {"eth0", "gmac0 present (RTL8211F)", &__MODULE__.iface?/1, "eth0"},
    {"eth1", "gmac1 present (RTL8211F)", &__MODULE__.iface?/1, "eth1"},
    {"wifi", "wlan0 present (BCM43752 SDIO, brcmfmac)", &__MODULE__.iface?/1, "wlan0"},
    {"gpu", "panfrost render node", &__MODULE__.render_node?/1, "panfrost"},
    {"npu", "rknpu render node (vendor driver)", &__MODULE__.render_node?/1, "rknpu"},
    {"drm", "HDMI DRM card", &__MODULE__.glob?/1, "/sys/class/drm/card?-HDMI*"},
    {"emmc", "eMMC is mmcblk0", &__MODULE__.grep?/1,
     {"/sys/class/block/mmcblk0/device/type", "MMC"}},
    {"rtc", "HYM8563 RTC", &__MODULE__.file?/1, "/dev/rtc0"},
    {"audio", "ALSA cards registered", &__MODULE__.grep?/1, {"/proc/asound/cards", "["}},
    {"app-fs", "/root mounted f2fs", &__MODULE__.grep?/1, {"/proc/mounts", "/root f2fs"}},
    {"env", "U-Boot env readable (fw_printenv)", &__MODULE__.uboot_env?/1, nil}
  ]

  def check do
    for {name, desc, fun, arg} <- @checks do
      status = if fun.(arg), do: "PASS", else: "FAIL"
      IO.puts("#{String.pad_trailing(name, 10)} #{status}  #{desc}")
    end

    :ok
  end

  @doc false
  def file?(path), do: File.exists?(path)

  @doc false
  def iface?(name) do
    case :inet.getifaddrs() do
      {:ok, ifs} -> List.keymember?(ifs, String.to_charlist(name), 0)
      _ -> false
    end
  end

  @doc false
  def glob?(pattern), do: Path.wildcard(pattern) != []

  @doc false
  def grep?({path, needle}) do
    case File.read(path) do
      {:ok, content} -> String.contains?(content, needle)
      _ -> false
    end
  end

  @doc false
  def render_node?(driver) do
    Path.wildcard("/sys/class/drm/renderD*/device/uevent")
    |> Enum.any?(fn f ->
      case File.read(f) do
        {:ok, content} -> String.contains?(content, driver)
        _ -> false
      end
    end)
  end

  @doc false
  def uboot_env?(_) do
    match?({_, 0}, System.cmd("fw_printenv", ["nerves_fw_active"], stderr_to_stdout: true))
  end
end
