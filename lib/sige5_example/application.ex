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

  # FirmwareValidator first, and deliberately ahead of the secure world.
  # Validation is what stops a freshly installed image being rolled back on the
  # next boot, so nothing optional may sit in front of it: a secure world that
  # will not start is a missing feature, and a firmware that never validates is
  # a device that silently reverts. Putting them the other way round once turned
  # the first into the second.
  #
  # tee-supplicant then, before anything that opens a TEE session, because a
  # session cannot be opened until it is serving.
  defp children(_target),
    do: [
      Sige5Example.FirmwareValidator,
      Sige5Example.TeeSupplicant,
      Sige5Example.SecureKey.server_child_spec()
    ]
end
