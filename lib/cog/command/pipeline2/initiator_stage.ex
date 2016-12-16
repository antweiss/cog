defmodule Cog.Command.Pipeline2.InitiatorStage do

  alias Experimental.GenStage
  alias Cog.Command.Pipeline2.Signal

  use GenStage

  defstruct [inputs: []]

  def start_link(opts) do
    GenStage.start_link(__MODULE__, [opts])
  end

  def init([inputs: inputs]) do
    {:producer, %__MODULE__{inputs: List.wrap(inputs)}}
  end

  def handle_demand(_count, %__MODULE__{inputs: []}=state) do
    # Inputs have all been processed so send a "done" signal
    {:noreply, [Signal.done()], state}
  end
  def handle_demand(count, %__MODULE__{inputs: inputs}=state) do
    {outputs, remaining} = Enum.split(inputs, count)
    outputs = Enum.map(outputs, &(%Signal{data: &1}))
    outputs = case remaining do
                [] ->
                  outputs ++ [Signal.done()]
                _ ->
                  outputs
              end
    {:noreply, outputs, %{state | inputs: remaining}}
  end

end
