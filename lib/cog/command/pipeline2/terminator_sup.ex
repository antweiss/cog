defmodule Cog.Command.Pipeline2.TerminatorSup do
  use Supervisor

  alias Cog.Command.Pipeline2.TerminatorStage

  def start_link,
    do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    children = [worker(TerminatorStage, [], restart: :temporary, shutdown: :brutal_kill)]
    supervise(children, strategy: :simple_one_for_one, max_restarts: 0, max_seconds: 1)
  end

  def create(opts), do: Supervisor.start_child(__MODULE__, [opts])

end
