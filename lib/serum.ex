defmodule Serum do
  @moduledoc """
  Defines Serum OTP application.

  Serum is a simple static website generator written in Elixir programming
  language. The goal of this project is to provide the way to create awesome
  static websites with little effort.

  This documentation is for developers and advanced users. For the getting
  started guide and the user manual, please visit [the official Serum
  website](https://dalgona.github.io/Serum).
  """

  use Application
  alias Serum.GlobalBindings
  alias Serum.Plugin
  alias Serum.Template

  @doc """
  Starts the `:serum` application.

  This starts a supervisor process which manages some children maintaining
  states or data required for execution of Serum.
  """
  def start(_type, _args) do
    children = [
      Template,
      GlobalBindings,
      Plugin
    ]

    opts = [strategy: :one_for_one, name: Serum.Supervisor]
    {:ok, _pid} = Supervisor.start_link(children, opts)
  end
end
