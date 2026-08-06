defmodule Sige5Example.WifiSoak do
  @moduledoc """
  Forces SDIO wake cycles on wlan0 and reports what the bus did.

  From the IEx console:

      Sige5Example.WifiSoak.run(minutes: 60)

  brcmfmac parks the SDIO bus after about 20ms idle - the watchdog runs every
  10ms (BRCMF_WD_POLL) and sleeps once idlecount passes idletime, which is 1 -
  so a packet every 100ms lands on a sleeping bus every time and forces a real
  KSO wake. An hour of that is roughly 36,000 wake cycles, against the 3.1
  failures per hour seen on ordinary traffic. The point is to reach a verdict
  in an hour instead of a week.

  A run ends with a throughput phase, because idle/wake and sustained transfer
  fail differently and a fix for one is not a fix for the other.

  Reported as PASS only on zero bus_sleep, txfail and backplane errors with
  unchanged wlan0 error counters.
  """

  @iface "wlan0"
  @stats "/sys/class/net/#{@iface}/statistics"

  # brcmfmac prefixes with the function name, so these match the message text.
  @patterns [
    {:bus_sleep, "error while changing bus sleep state"},
    {:txfail, "sdio error, abort command and terminate frame"},
    {:backplane, "failed backplane access"},
    {:kso_failed, "kso 1 failed"}
  ]

  @doc """
  Run the soak. Options:

    * `:minutes` - wake-cycle phase length, default 60
    * `:interval_ms` - time between forced wakes, default 100
    * `:throughput_seconds` - sustained-send phase, default 60 (0 to skip)
  """
  def run(opts \\ []) do
    minutes = Keyword.get(opts, :minutes, 60)
    interval = Keyword.get(opts, :interval_ms, 100)
    throughput = Keyword.get(opts, :throughput_seconds, 60)

    with {:ok, target} <- target_address(),
         {:ok, socket} <- open() do
      before = snapshot()

      IO.puts("wifi soak: #{minutes} min, wake every #{interval} ms, target #{fmt_ip(target)}")
      wakes = wake_phase(socket, target, minutes * 60_000, interval)

      sent =
        if throughput > 0 do
          IO.puts("throughput: #{throughput} s")
          throughput_phase(socket, target, throughput * 1000)
        else
          0
        end

      :gen_udp.close(socket)
      report(before, snapshot(), wakes, sent)
    else
      {:error, reason} ->
        IO.puts("wifi soak: cannot start - #{inspect(reason)}")
        :error
    end
  end

  # Bind to the interface, not just its address: a source-address bind still
  # lets policy routing pick another link, and a soak that runs over eth0
  # would report a clean bus that was never asked to wake.
  defp open do
    :gen_udp.open(0, [:binary, {:bind_to_device, @iface}, {:active, false}])
  end

  defp wake_phase(socket, target, duration_ms, interval) do
    start = now()
    tick(socket, target, start + duration_ms, interval, 0, start + 300_000, start)
  end

  defp tick(socket, target, deadline, interval, count, next_note, next_at) do
    if now() >= deadline do
      count
    else
      :gen_udp.send(socket, target, 9, "wake")

      next_note =
        if now() >= next_note do
          IO.puts("  #{count} wakes, #{minutes_left(deadline)} min left")
          now() + 300_000
        else
          next_note
        end

      # Sleep to an absolute schedule, so the cost of the send does not creep
      # into the idle gap - that gap is the thing being measured, and it has
      # to stay comfortably above the ~20ms the bus waits before parking.
      next_at = next_at + interval
      Process.sleep(max(next_at - now(), 0))
      tick(socket, target, deadline, interval, count + 1, next_note, next_at)
    end
  end

  # No sleeps: the bus stays awake, which exercises transfer rather than wake.
  defp throughput_phase(socket, target, duration_ms) do
    deadline = now() + duration_ms
    payload = :binary.copy(<<0>>, 1400)
    blast(socket, target, deadline, payload, 0)
  end

  defp blast(socket, target, deadline, payload, count) do
    if now() >= deadline do
      count
    else
      :gen_udp.send(socket, target, 9, payload)
      blast(socket, target, deadline, payload, count + 1)
    end
  end

  defp snapshot do
    %{
      rx_errors: counter("rx_errors"),
      tx_errors: counter("tx_errors"),
      rx_packets: counter("rx_packets"),
      tx_packets: counter("tx_packets"),
      kmsg: kmsg_mark()
    }
  end

  defp counter(name) do
    case File.read("#{@stats}/#{name}") do
      {:ok, raw} -> raw |> String.trim() |> String.to_integer()
      _ -> -1
    end
  end

  # The timestamp of the newest kernel message, so the end-of-run count can
  # ignore everything that was already there.
  defp kmsg_mark do
    kmsg()
    |> Enum.reverse()
    |> Enum.find_value(0.0, &timestamp/1)
  end

  defp kmsg do
    case System.cmd("dmesg", [], stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\n")
      _ -> []
    end
  rescue
    # No dmesg in the image: counters and the PASS/FAIL on them still work.
    _ -> []
  end

  defp timestamp(line) do
    case Regex.run(~r/^\[\s*(\d+\.\d+)\]/, line) do
      [_, ts] -> String.to_float(ts)
      _ -> nil
    end
  end

  defp report(before, now_snap, wakes, sent) do
    all = kmsg()
    lines = Enum.filter(all, &newer_than(&1, before.kmsg))
    counts = Enum.map(@patterns, fn {key, text} -> {key, count_matching(lines, text)} end)

    # Every message still in the buffer post-dates the mark, so whatever was
    # there when the run started has scrolled out and the counts undercount.
    wrapped? = lines != [] and Enum.all?(timestamped(all), &newer_than(&1, before.kmsg))

    IO.puts("\n#{@iface} soak result")
    IO.puts("  wakes forced        #{wakes}")
    IO.puts("  throughput sends    #{sent}")

    for {key, n} <- counts do
      IO.puts("  #{String.pad_trailing(to_string(key), 20)}#{n}")
    end

    for field <- [:rx_errors, :tx_errors, :rx_packets, :tx_packets] do
      a = Map.fetch!(before, field)
      b = Map.fetch!(now_snap, field)
      IO.puts("  #{String.pad_trailing(to_string(field), 20)}#{a} -> #{b}  (+#{b - a})")
    end

    case last_matching(lines, "kso 1 worst") do
      nil -> IO.puts("  kso worst           (no line - no handshake needed a retry)")
      line -> IO.puts("  kso worst           #{String.trim(line)}")
    end

    if wrapped?, do: IO.puts("  NOTE: kernel log wrapped, error counts are a lower bound")

    errors = Enum.reduce(counts, 0, fn {_, n}, acc -> acc + n end)
    drift = now_snap.rx_errors - before.rx_errors + (now_snap.tx_errors - before.tx_errors)

    verdict = if errors == 0 and drift == 0 and not wrapped?, do: "PASS", else: "FAIL"
    IO.puts("  RESULT              #{verdict}")

    %{verdict: verdict, wakes: wakes, counts: Map.new(counts), wrapped: wrapped?}
  end

  defp timestamped(lines), do: Enum.filter(lines, &(timestamp(&1) != nil))

  defp newer_than(line, mark) do
    case timestamp(line) do
      nil -> false
      ts -> ts > mark
    end
  end

  defp count_matching(lines, text), do: Enum.count(lines, &String.contains?(&1, text))

  defp last_matching(lines, text) do
    lines |> Enum.filter(&String.contains?(&1, text)) |> List.last()
  end

  # The default route for wlan0. Sending to the gateway keeps the traffic on
  # the link and off the wider network.
  defp target_address do
    case File.read("/proc/net/route") do
      {:ok, raw} ->
        raw
        |> String.split("\n")
        |> Enum.find_value({:error, :no_route}, &parse_route/1)

      _ ->
        {:error, :no_proc_net_route}
    end
  end

  defp parse_route(line) do
    case String.split(line) do
      [@iface, "00000000", gateway | _] -> decode_gateway(gateway)
      _ -> nil
    end
  end

  # /proc/net/route holds the address little-endian, as eight hex digits.
  defp decode_gateway(hex) do
    with {value, ""} <- Integer.parse(hex, 16),
         <<d, c, b, a>> <- <<value::32>> do
      {:ok, {a, b, c, d}}
    else
      _ -> nil
    end
  end

  defp fmt_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"

  defp minutes_left(deadline), do: div(max(deadline - now(), 0), 60_000)

  defp now, do: System.monotonic_time(:millisecond)
end
