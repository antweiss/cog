defmodule Cog.Command.Pipeline2.TerminatorStage do

  alias Experimental.GenStage
  alias Cog.Chat.Adapter, as: ChatAdapter
  alias Cog.Command.Pipeline2.Signal
  alias Cog.Command.ReplyHelper
  alias Cog.Template.New, as: Template
  alias Cog.Template.New.Evaluator

  defstruct [
    executor: nil,
    destinations: nil,
    results: []
  ]

  use GenStage

  def start_link(opts) do
    GenStage.start_link(__MODULE__, [opts])
  end

  def init([opts]) do
    upstream = Keyword.fetch!(opts, :upstream)
    executor = Keyword.fetch!(opts, :executor)
    destinations = Keyword.fetch!(opts, :destinations)
    {:consumer, %__MODULE__{executor: executor, destinations: destinations}, subscribe_to: [upstream]}
  end

  def handle_events(events, _from, state) do
    state = %{state | results: state.results ++ events}
    if List.last(events) == Signal.done() do
      Enum.map(state.results, &(respond(&1, state)))
    end
    {:noreply, [], state}
  end

  defp respond(signal, state) do
    ########################################################################
    # NEW TEMPLATE PROCESSING
    ########################################################################
    template_name = signal.template
    by_output_level = Enum.group_by(state.destinations, &(&1.output_level))

    # Render full output first
    full = Map.get(by_output_level, :full, [])

    directives = Evaluator.evaluate(signal.bundle_version_id,
                                    template_name,
                                    Template.with_envelope(signal.data))

    Enum.each(full, fn(dest) ->
      # TODO: Might want to push this iteration into the provider
      # itself. Otherwise, we have to pull the provider logic into
      # here to render the directives once.

      payload = ReplyHelper.choose_payload(dest.adapter, directives, signal.data)
      ChatAdapter.send(dest.adapter, dest.room, payload)
    end)

    # Now for status only
    by_output_level
    |> Map.get(:status_only, [])
    |> Enum.each(fn(dest) ->
      # TODO: For the mesasge typing to work out, this has to be a
      # bare string... let's find a less hacky way to address things
      ChatAdapter.send(dest.adapter, dest.room, "ok")
    end)
  end

end
