defmodule Cog.Command.Pipeline2.InitiatorStage do

  alias Experimental.GenStage
  alias Cog.Command.Pipeline2.Signal

  use GenStage
  require Logger

  defstruct [pipeline_id: nil,
             inputs: []]

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  def init(opts) do
    inputs = Keyword.fetch!(opts, :inputs)
    pipeline_id = Keyword.fetch!(opts, :pipeline_id)
    {:producer, %__MODULE__{inputs: List.wrap(inputs), pipeline_id: pipeline_id}}
  end

  def handle_demand(_count, %__MODULE__{inputs: []}=state) do
    # Inputs have all been processed so send a "done" signal
    {:noreply, [Signal.done()], state}
  end
  def handle_demand(count, %__MODULE__{inputs: inputs}=state) do
    {outputs, remaining} = Enum.split(inputs, count)
    outputs = case remaining do
                [] ->
                  outputs ++ [Signal.done()]
                _ ->
                  outputs
              end
    {:noreply, outputs, %{state | inputs: remaining}}
  end

  def terminate(reason, state) do
    Logger.debug("Initiator stage for pipeline #{state.pipeline_id} stopped: #{inspect reason}")
  end

end