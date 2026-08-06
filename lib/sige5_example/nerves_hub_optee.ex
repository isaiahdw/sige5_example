# nerves_hub_link is a target-only dependency, so this is skipped on the host
# where mix tasks run.
if Code.ensure_loaded?(NervesHubLink.Configurator) do
  defmodule Sige5Example.NervesHubOptee do
    @moduledoc """
    Authenticate to NervesHub with the device key held in the secure world.

    The certificate is public and lives on the data partition. The private key
    is a handle into OP-TEE: `:ssl` hands every signature to the engine, which
    hands it to the TA, so the key itself is never in this process's memory.

    Run `Sige5Example.SecureKey.provision/1` once to create the key and
    certificate, then register the certificate against the device in NervesHub.

    On a board with no secure world this leaves the SSL options untouched and
    says so, rather than failing to start — the same firmware runs on boards
    that have not been provisioned.
    """

    @behaviour NervesHubLink.Configurator

    alias NervesHubLink.Certificate
    alias NervesHubLink.Configurator.Config
    alias Sige5Example.SecureKey

    require Logger

    @impl NervesHubLink.Configurator
    def build(%Config{} = config) do
      case SecureKey.certificate_der() do
        nil ->
          Logger.info("[NervesHubOptee] no device certificate; run SecureKey.provision/1")
          config

        cert ->
          ssl =
            config.ssl
            |> Keyword.put_new(:cert, cert)
            |> Keyword.put_new_lazy(:key, &SecureKey.private_key/0)
            |> Keyword.put_new(:cacerts, Certificate.ca_certs())

          %{config | ssl: ssl}
      end
    end
  end
end
