defmodule Cog.Command.Pipeline2.PipelineSup do
  use Supervisor

  alias Cog.Command

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    children = [supervisor(Command.Pipeline2.ExecutorSup, []),
                supervisor(Command.Pipeline2.InitiatorSup, []),
                supervisor(Command.Pipeline2.InvokeSup, []),
                supervisor(Command.Pipeline2.TerminatorSup, [])]
    supervise(children, strategy: :one_for_one)
  end

end
