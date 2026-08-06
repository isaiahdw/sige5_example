defmodule Sige5Example.MixProject do
  use Mix.Project

  @app :sige5_example
  @version "0.1.0"
  @all_targets [:sige5]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      archives: [nerves_bootstrap: "~> 1.15"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Sige5Example.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host]]
  end

  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      {:nerves_runtime, "~> 0.13.12"},

      # Networking + SSH + mDNS + time for all real targets
      {:nerves_pack, "~> 0.7.1", targets: @all_targets},

      # Device management: connects to NervesHub for OTA updates and remote
      # console.
      {:nerves_hub_link, "~> 2.12", targets: @all_targets},

      # Certificates, on the device and in mix sige5.provision
      {:x509, "~> 0.8"},

      # supervises tee-supplicant, which the secure world needs to store keys
      {:muontrap, "~> 1.5", targets: @all_targets},

      # Dependencies for specific targets
      # Nerves system for the Radxa ROCK 4D (RK3576). The prebuilt system
      # artifact is downloaded from the GitHub release for this tag. For
      # local system development, switch to
      # `path: "../nerves_system_sige5", nerves: [compile: true]`.
      {:nerves_system_sige5,
       path: "../nerves_system_sige5", runtime: false, nerves: [compile: true], targets: :sige5}
    ]
  end

  def release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end
end
