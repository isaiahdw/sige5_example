defmodule Sige5Example.SecureKey do
  @moduledoc """
  A device identity whose private key never leaves the secure world.

  The key is an EC P-256 keypair generated inside OP-TEE's PKCS #11 token,
  marked sensitive and non-extractable, so the trusted application will not
  hand the private half back. Signing happens in TrustZone; this application
  only ever sees signatures.

  `provision/1` sets that up and returns what is needed to get a certificate
  issued:

      iex> Sige5Example.SecureKey.provision()
      %{
        serial_number: "2a2e1131348a",
        csr: "-----BEGIN CERTIFICATE REQUEST-----\\n..."
      }

  The request is signed by the key in the secure world, so a CSR that verifies
  is evidence the key works. `mix sige5.provision` signs it with the device CA
  and installs the result; by hand, sign the request on a machine holding the
  CA key and put the certificate back with `store_certificate/1`.

  What this protects against: nobody who takes the eMMC or reads the
  filesystem can obtain the private key, because there is no copy of it to
  find. What it does not: code already running as root here can ask the secure
  world to sign, the same as any hardware key without a per-use PIN.

  Every PKCS #11 call goes through `/usr/bin/optee-key`, kept running by
  `Sige5Example.SecureKey.Server` with one TEE session open.

  Requires a secure-world bootloader (`SECURE_WORLD=1 ./scripts/build-uboot.sh`)
  and a fused HUK.
  """

  require Logger
  require X509.ASN1

  alias Sige5Example.SecureKey.Server

  @tool "/usr/bin/optee-key"
  @token "sige5"
  @key_label "nerveshub"
  @cert_path "/data/nerveshub/device-cert.pem"

  # The token PIN is not a secret and cannot be one: the device boots
  # unattended, so anything it can reach, root can reach too. PKCS #11 requires
  # a PIN to create private objects; the protection comes from the key being
  # non-extractable, not from this.
  @so_pin "sige5-so"
  @pin "sige5"

  @doc """
  Generate the device key if it does not exist and return a request for it.

  Reuses an existing key rather than replacing it, since a new key orphans
  whatever certificate was issued against the old one. Pass `force: true` to
  start over.
  """
  @spec provision(keyword()) :: %{serial_number: String.t(), csr: String.t()}
  def provision(opts \\ []) do
    :ok = ensure_key(Keyword.get(opts, :force, false))

    %{serial_number: serial_number(), csr: build_csr()}
  end

  @doc """
  A certificate signing request for the device key, as PEM.

  Sign it on a machine that holds the CA key - `mix sige5.provision` does
  that - and upload the certificate to NervesHub against this serial number.
  """
  @spec csr() :: String.t()
  def csr do
    :ok = ensure_key(false)
    build_csr()
  end

  @doc "The identifier NervesHub knows this device by."
  @spec serial_number() :: String.t()
  def serial_number, do: Nerves.Runtime.serial_number()

  @doc "The stored device certificate in DER, for `:ssl` options."
  @spec certificate_der() :: binary() | nil
  def certificate_der do
    case File.read(@cert_path) do
      {:ok, pem} -> pem |> X509.Certificate.from_pem!() |> X509.Certificate.to_der()
      _ -> nil
    end
  end

  @doc "Store a certificate issued for this device's key."
  @spec store_certificate(String.t()) :: :ok
  def store_certificate(pem) do
    # Fail here rather than at the next TLS handshake
    _ = X509.Certificate.from_pem!(pem)
    File.mkdir_p!(Path.dirname(@cert_path))
    File.write!(@cert_path, pem)
  end

  @doc """
  The private key for `:ssl` options: a callback, not key material.

  `:ssl` hands each signature to `sign/3`, which passes it to the secure
  world. Supported since OTP 27.
  """
  @spec private_key() :: map()
  def private_key, do: %{algorithm: :ecdsa, sign_fun: &__MODULE__.sign/3}

  @doc """
  Sign with the device key. `:ssl` calls this; it is not usually called directly.

  The message arrives as plaintext to be hashed, not as a digest, so the
  digest is computed here - CKM_ECDSA in the token signs a digest.
  """
  @spec sign(binary(), atom(), keyword()) :: binary()
  def sign(message, digest_type, _opts \\ []) do
    message
    |> then(&:crypto.hash(digest_type, &1))
    |> Server.sign()
  end

  @doc "What is present, for working out why this is not running."
  @spec status() :: map()
  def status do
    %{
      tee_device: File.exists?("/dev/tee0"),
      tool: File.exists?(@tool),
      certificate: File.exists?(@cert_path),
      tokens: if(File.exists?(@tool), do: tokens(), else: [])
    }
  end

  @doc "Token state as the trusted application reports it."
  @spec tokens() :: [String.t()]
  def tokens do
    case run(["info"]) do
      {:ok, out} -> String.split(String.trim(out), "\n", trim: true)
      {:error, reason} -> ["error: #{reason}"]
    end
  end

  defp ensure_key(force) do
    unless File.exists?("/dev/tee0") do
      raise """
      No /dev/tee0, so there is no secure world to hold a key.

          SECURE_WORLD=1 ./scripts/build-uboot.sh

      That image fuses a hardware unique key on the first boot of a part that
      has none, which is irreversible.
      """
    end

    unless File.exists?(@tool) do
      raise "#{@tool} is missing - the system needs BR2_PACKAGE_OPTEE_KEY"
    end

    unless token_initialised?() do
      Logger.info("[SecureKey] initialising the PKCS #11 token")
      {:ok, _} = run(["init", @token], so_pin: true)
    end

    if force or not key_present?() do
      Logger.info("[SecureKey] generating an EC P-256 key inside the secure world")
      {:ok, _} = run(["generate", @token, @key_label])
    end

    :ok
  end

  defp token_initialised? do
    case run(["info"]) do
      {:ok, out} -> String.contains?(out, ~s(label="#{@token}))
      _ -> false
    end
  end

  defp key_present?, do: match?({:ok, _}, run(["pubkey", @token, @key_label]))

  @doc false
  def server_child_spec,
    do: {Server, token: @token, pin: @pin, key_label: @key_label}

  defp public_key, do: Server.public_key() |> X509.PublicKey.from_der!()

  defp subject, do: X509.RDNSequence.new("/CN=#{serial_number()}")

  # X509.CSR.new/3 works out the signature algorithm from the key, and it can
  # do that only for a key record or an engine reference - a :sign_fun map
  # matches neither. The assembly is short enough to do here: build the info,
  # sign it in the secure world, wrap the two together.
  defp build_csr do
    info =
      X509.ASN1.certification_request_info(
        version: :v1,
        subject: :pubkey_cert_records.transform(subject(), :encode),
        subjectPKInfo:
          X509.PublicKey.wrap(public_key(), :CertificationRequestInfo_subjectPKInfo),
        attributes: []
      )

    info_der = :public_key.der_encode(:CertificationRequestInfo, info)

    X509.ASN1.certification_request(
      certificationRequestInfo: info,
      signatureAlgorithm:
        X509.SignatureAlgorithm.new(:sha256, :ecdsa, :CertificationRequest_signatureAlgorithm),
      signature: sign(info_der, :sha256)
    )
    |> X509.CSR.to_pem()
  end

  # Run the helper from a process of its own. System.cmd opens the port from
  # whatever process calls it, and :ssl calls sign/3 inline in its connection
  # process - the helper's {:EXIT, port, :normal} then lands in the TLS state
  # machine's mailbox, which logs it as an unexpected INFO message.
  # PINs go in the environment. /proc/<pid>/cmdline is world-readable, so an
  # argument is visible to every process for as long as the command runs.
  defp run(args, opts \\ []) do
    env = [{"OPTEE_KEY_PIN", @pin}]
    env = if opts[:so_pin], do: [{"OPTEE_KEY_SO_PIN", @so_pin} | env], else: env

    task =
      Task.async(fn -> System.cmd(@tool, args, stderr_to_stdout: true, env: env) end)

    case Task.await(task, 30_000) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, "optee-key #{hd(args)} exited #{code}: #{String.trim(out)}"}
    end
  end

end
