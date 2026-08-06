defmodule Mix.Tasks.Sige5.Provision do
  @shortdoc "Issue a certificate for a device key held in the secure world"

  @moduledoc """
  Give a device an identity backed by its secure world.

      mix sige5.provision sige5.local

  Asks the device for a certificate request, signs it with the device CA,
  installs the certificate, and prints the serial number to register in
  NervesHub. The CA is created on first use.

  Signing with a CA is what lets you decide which devices may hold a valid
  identity: a device can always make a key and sign for itself, but only this
  CA's holder can issue a certificate the fleet trusts. Its private key stays
  here and never goes to a device - in production it belongs in an HSM or on
  an offline machine, not in a working directory.

  Options:

    * `--ca` - directory holding the CA (default `ca`)
    * `--validity` - certificate lifetime in days (default 3650)
  """

  use Mix.Task

  @ssh_opts [
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "ConnectTimeout=10"
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: [ca: :string, validity: :integer])

    host =
      case args do
        [host] -> host
        _ -> Mix.raise("usage: mix sige5.provision <ip-or-hostname>")
      end

    ca_dir = Keyword.get(opts, :ca, "ca")
    validity = Keyword.get(opts, :validity, 3650)

    ca_signed(host, load_or_create_ca(ca_dir), ca_dir, validity)
  end

  defp ca_signed(host, {ca_cert, ca_key}, ca_dir, validity) do
    Mix.shell().info("asking #{host} for a certificate request")
    %{serial: serial, csr: csr} = request_from_device(host)
    Mix.shell().info("  serial number: #{serial}")

    Mix.shell().info("signing with the CA in #{ca_dir}")
    cert = issue(csr, serial, ca_cert, ca_key, validity)

    cert_path = Path.join(ca_dir, "#{serial}.crt")
    File.write!(cert_path, X509.Certificate.to_pem(cert))

    Mix.shell().info("installing the certificate on #{host}")
    install(host, X509.Certificate.to_pem(cert))

    Mix.shell().info("""

    done. #{host} holds a key it cannot export and a certificate for it.

      serial number: #{serial}
      certificate:   #{cert_path}
      CA:            #{Path.join(ca_dir, "rootCA.crt")}

    Add a device with that serial number in NervesHub and upload the
    certificate against it.
    """)
  end

  defp request_from_device(host) do
    serial = device(host, "IO.puts(Sige5Example.SecureKey.serial_number())") |> List.first()

    pem =
      device(host, "IO.puts(Sige5Example.SecureKey.provision().csr)")
      |> pem_between("CERTIFICATE REQUEST")

    csr =
      case X509.CSR.from_pem(pem) do
        {:ok, csr} -> csr
        _ -> Mix.raise("#{host} did not return a certificate request")
      end

    unless X509.CSR.valid?(csr) do
      Mix.raise("the request's signature does not verify - the device did not sign it")
    end

    %{serial: serial, csr: csr}
  end

  # The console echoes the expression's return value onto the first line of
  # output, so trim anything before the PEM header.
  defp pem_between(lines, label) do
    lines
    |> Enum.drop_while(&(not String.contains?(&1, "BEGIN #{label}")))
    |> Enum.take_while(&(not String.contains?(&1, "END #{label}")))
    |> Kernel.++(["-----END #{label}-----"])
    |> List.update_at(0, &Regex.replace(~r/^.*-----BEGIN/, &1, "-----BEGIN"))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp device(host, code) do
    case System.cmd("ssh", @ssh_opts ++ [host, code], stderr_to_stdout: false) do
      {out, 0} -> out |> String.replace("\r", "") |> String.split("\n", trim: true)
      _ -> Mix.raise("could not reach #{host}")
    end
  end

  defp load_or_create_ca(dir) do
    key_path = Path.join(dir, "rootCA.key")
    cert_path = Path.join(dir, "rootCA.crt")

    if File.exists?(key_path) do
      {File.read!(cert_path) |> X509.Certificate.from_pem!(),
       File.read!(key_path) |> X509.PrivateKey.from_pem!()}
    else
      Mix.shell().info("creating a device CA in #{dir}")
      File.mkdir_p!(dir)

      key = X509.PrivateKey.new_ec(:secp256r1)
      cert = X509.Certificate.self_signed(key, "/CN=Sige5 Device CA", template: :root_ca)

      File.write!(key_path, X509.PrivateKey.to_pem(key))
      File.chmod!(key_path, 0o600)
      File.write!(cert_path, X509.Certificate.to_pem(cert))

      {cert, key}
    end
  end

  # NervesHub identifies the device by the certificate's common name, so it has
  # to be the serial number the device reports.
  defp issue(csr, serial, ca_cert, ca_key, validity) do
    subject = X509.CSR.subject(csr)

    unless subject |> X509.RDNSequence.get_attr(:commonName) |> List.first() == serial do
      Mix.raise("the request's common name is not #{serial}")
    end

    X509.Certificate.new(
      X509.CSR.public_key(csr),
      subject,
      ca_cert,
      ca_key,
      validity: validity,
      extensions: [
        basic_constraints: X509.Certificate.Extension.basic_constraints(false),
        key_usage: X509.Certificate.Extension.key_usage([:digitalSignature]),
        ext_key_usage: X509.Certificate.Extension.ext_key_usage([:clientAuth])
      ]
    )
  end

  defp install(host, pem) do
    # Send it as one line and let the device put the newlines back, so no
    # quoting has to survive the trip through the shell and IEx.
    flat = String.replace(pem, "\n", "~")

    device(
      host,
      ~s|Sige5Example.SecureKey.store_certificate(String.replace("#{flat}", "~", "\\n"))|
    )

    case device(host, "IO.puts(Sige5Example.SecureKey.status().certificate)") do
      ["true" | _] -> :ok
      _ -> Mix.raise("the certificate did not install")
    end
  end
end
