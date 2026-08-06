# Loaded at IEx session start on the device (serial console and ssh).

# Add Toolshed helpers (uname/0, cmd/1, weather/0, ...)
use Toolshed

if RingLogger in Application.get_env(:logger, :backends, []) do
  IO.puts("RingLogger is collecting log messages from Elixir and Linux. To see the")
  IO.puts("messages, either attach the current IEx session to the logger:")
  IO.puts("")
  IO.puts("    RingLogger.attach")
  IO.puts("")
  IO.puts("or print the next messages in the log:")
  IO.puts("")
  IO.puts("    RingLogger.next")
  IO.puts("")
end

if Code.ensure_loaded?(NervesMOTD) do
  NervesMOTD.print()
end
