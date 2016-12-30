defmodule Cog.Command.Pipeline2.PipelineSup do
  use Supervisor

  alias Cog.Command

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    children = [supervisor(Command.Pipeline2.ExecutorSup, [], shutdown: 100),
                supervisor(Command.Pipeline2.InitiatorSup, [], shutdown: 100),
                supervisor(Command.Pipeline2.InvokeSup, [], shutdown: 100),
                supervisor(Command.Pipeline2.TerminatorSup, [], shutdown: 100)]
    supervise(children, strategy: :one_for_one)
  end

end
