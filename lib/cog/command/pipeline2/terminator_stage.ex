defmodule Cog.Command.Pipeline2.TerminatorStage do

  alias Experimental.GenStage
  alias Cog.Command.Pipeline.Destination
  alias Cog.Chat.Adapter, as: ChatAdapter
  alias Cog.Command.Pipeline2.{Executor, Signal}
  alias Cog.ErrorResponse
  alias Cog.Template
  alias Cog.Template.Evaluator

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
    :erlang.monitor(:process, executor)
    {:consumer, %__MODULE__{pipeline_id: pipeline_id,
                            executor: executor, destinations: destinations}, subscribe_to: [upstream]}
  end

  def handle_events(events, _from, state) do
    state = %{state | results: state.results ++ events}
    last_event  = List.last(events)
    if Signal.done?(last_event) or Signal.failed?(last_event) do
      # Send output to destinations
      Enum.each(state.results, &(respond(&1, state)))
      # Tell executor we're done
      Executor.notify(state.executor)
    end
    {:noreply, [], state}
  end

  def handle_info({:DOWN, _, :process, pid, _}, %__MODULE__{executor: executor}=state) when pid == executor do
    {:stop, :shutdown, state}
  end

  def terminate(reason, state) do
    Logger.debug("Terminator stage for pipeline #{state.pipeline_id} stopped: #{inspect reason}")
  end

  defp respond(signal, state) do
    if Signal.done?(signal) do
      # Pipeline terminated early with no results
      if length(state.results) == 1 do
        signal = %{signal | bundle_version_id: "common", template: "early-exit"}
        early_exit_response(signal, state)
      end
    else
      if Signal.failed?(signal) do
        request = Executor.get_request(state.executor)
        started = Executor.get_started(state.executor)
        destinations = here_destination(request)
        destinations
        |> Map.keys
        |> Enum.each(&error_response(&1, destinations, signal, request, started, state))
      else
        state.destinations
        |> Map.keys
        |> Enum.each(&success_response(&1, signal, state))
      end
    end
  end

  defp early_exit_response(signal, state) do
    request = Executor.get_request(state.executor)
    destinations = here_destination(request)
    Enum.each(destinations, fn({type, destinations}) ->
                              output = output_for(type, signal, "success", "Terminated early")
                             Enum.each(destinations, &ChatAdapter.send(&1.adapter, &1.room, output)) end)
  end

  defp success_response(type, signal, state) do
    output = output_for(type, signal, "success", nil)
    state.destinations
    |> Map.get(type)
    |> Enum.each(&ChatAdapter.send(&1.adapter, &1.room, output))
  end

  defp error_response(type, destinations, signal, request, started, state) do
    message = render_error_message(signal)
    error_context = %{"id" => state.pipeline_id,
                      "started" => started,
                      "initiator" => sender_name(request),
                      "pipeline_text" => request.text,
                      "message" => message,
                      "planning_failure" => "",
                      "execution_failure" => ""}
    signal = %{signal | data: error_context}
    output = output_for(type, signal, "error", message)
    destinations
    |> Map.get(type)
    |> Enum.each(&ChatAdapter.send(&1.adapter, &1.room, output))
  end

  defp render_error_message(signal) do
    cond do
      signal.data == :timeout ->
        ErrorResponse.render({signal.data, signal.invocation})
      signal.data == :denied ->
        invocation = Map.get(signal.invocation, :invocation)
        rule = Map.get(signal.invocation, :rule)
        ErrorResponse.render({:denied, {rule, invocation}})
      true ->
        ErrorResponse.render(signal.data)
    end
  end

  defp output_for(:chat, signal, _, _) do
    output   = signal.data
    bundle_vsn = signal.bundle_version_id
    template_name = signal.template
    if bundle_vsn == "common" do
        if template_name in ["error", "unregistered-user"] do
          # No "envelope" for these templates right now
          Evaluator.evaluate(template_name, output)
        else
          Evaluator.evaluate(template_name, Template.with_envelope(output))
        end
    else
      Evaluator.evaluate(bundle_vsn, template_name, Template.with_envelope(output))
    end
   end
  defp output_for(:trigger, signal, status, message) do
    if Signal.failed?(signal) do
      %{status: status, pipeline_output: %{error_message: message}}
    else
        envelope = %{status: status,
                     pipeline_output: List.wrap(signal.data)}
      if message do
        Map.put(envelope, :message, message)
      else
        envelope
      end
    end
  end
  defp output_for(:status_only, signal, status, message) do
    if Signal.failed?(signal) do
      %{status: status, pipeline_output: %{error_message: message}}
    else
      %{status: status}
    end
  end

  defp sender_name(request) do
    if ChatAdapter.is_chat_provider?(request.adapter) do
      "@#{request.sender.handle}"
    else
      request.sender.id
    end
  end

  defp here_destination(request) do
    {:ok, destinations} = Destination.process(["here"], request.sender, request.room, request.adapter)
    destinations
  end

end
