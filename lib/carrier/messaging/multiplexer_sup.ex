defmodule Carrier.Messaging.MultiplexerSup do
  use Supervisor

  def start_link,
    do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    children = [worker(Carrier.Messaging.Multiplexer, [], restart: :temporary)]
    supervise(children, strategy: :simple_one_for_one, max_restarts: 0, max_seconds: 1)
  end

  def connect(opts \\ []), do: Supervisor.start_child(__MODULE__, [opts])

end
