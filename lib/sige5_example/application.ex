defmodule Sige5Example.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = children(Application.get_env(:sige5_example, :target, :host))

    opts = [strategy: :one_for_one, name: Sige5Example.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp children(:host), do: []

  # tee-supplicant first: anything that touches the secure world needs it
  # already running, and nothing here needs the TEE before it.
  defp children(_target),
    do: [
      Sige5Example.TeeSupplicant,
      Sige5Example.SecureKey.server_child_spec(),
      Sige5Example.FirmwareValidator
    ]
end
