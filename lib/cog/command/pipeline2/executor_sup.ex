defmodule Cog.Command.Pipeline2.ExecutorSup do
  use Supervisor

  alias Cog.Command.Pipeline2.Executor

  def start_link,
    do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init(_) do
    children = [worker(Executor, [], restart: :temporary, shutdown: :brutal_kill)]
    supervise(children, strategy: :simple_one_for_one, max_restarts: 0, max_seconds: 1)
  end

  def run(opts) do
    case Supervisor.start_child(__MODULE__, [opts]) do
      {:ok, pid} ->
        Executor.run(pid)
        {:ok, pid}
      error ->
        error
    end
  end

end
