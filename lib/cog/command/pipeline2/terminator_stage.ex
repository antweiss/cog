defmodule Cog.Command.Pipeline2.TerminatorStage do

  alias Experimental.GenStage
  alias Cog.Chat.Adapter, as: ChatAdapter
  alias Cog.Command.Pipeline2.{Executor, Signal}
  alias Cog.Command.ReplyHelper
  alias Cog.ErrorResponse
  alias Cog.Template.New, as: Template
  alias Cog.Template.New.Evaluator

  defstruct [
    pipeline_id: nil,
    executor: nil,
    destinations: nil,
    results: []
  ]

  use GenStage

  require Logger

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  def init(opts) do
    pipeline_id = Keyword.fetch!(opts, :pipeline_id)
    upstream = Keyword.fetch!(opts, :upstream)
    executor = Keyword.fetch!(opts, :executor)
    destinations = Keyword.fetch!(opts, :destinations)
    {:consumer, %__MODULE__{pipeline_id: pipeline_id,
                            executor: executor, destinations: destinations}, subscribe_to: [upstream]}
  end

  def handle_events(events, _from, state) do
    state = %{state | results: state.results ++ events}
    if List.last(events) == Signal.done() do
      # Send output to destinations
      Enum.each(state.results, &(respond(&1, state)))
      # Tell executor we're done
      Executor.notify(state.executor)
    end
    {:noreply, [], state}
  end

  def terminate(reason, state) do
    Logger.debug("Terminator stage for pipeline #{state.pipeline_id} stopped: #{inspect reason}")
  end

  defp respond(signal, state) do
    unless signal == Signal.done() do
      if signal.failed do
        error_response(signal, state)
      else
        success_response(signal, state)
      end
    end
  end

  defp success_response(signal, state) do
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

  defp error_response(signal, state) do
    request = Executor.get_request(state.executor)
    error_context = %{"id" => state.pipeline_id,
                      "initiator" => sender_name(request),
                      "pipeline_text" => request.text,
                      "error_message" => ErrorResponse.render(signal.data),
                      "planning_failure" => "",
                      "execution_failure" => ""}
    payload = if ChatAdapter.is_chat_provider?(request.adapter) do
      Evaluator.evaluate("error", error_context)
    else
      error_context
    end
    ChatAdapter.send(request.adapter, request.room, payload)
  end

  defp sender_name(request) do
    if ChatAdapter.is_chat_provider?(request.adapter) do
      "@#{request.sender.handle}"
    else
      request.sender.id
    end
  end

end
