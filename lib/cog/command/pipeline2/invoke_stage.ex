defmodule Cog.Command.Pipeline2.InvokeStage do

  alias Experimental.GenStage

  alias Carrier.Messaging.Multiplexer
  alias Cog.Command.{OptionInterpreter, PermissionInterpreter}
  alias Cog.Command.Pipeline.Binder
  alias Cog.Command.Pipeline2.Signal
  alias Cog.Events.PipelineEvent
  alias Cog.Messages.CommandResponse
  alias Cog.Relay.Relays
  alias Cog.ServiceEndpoint
  alias Piper.Command.Ast.BadValueError

  use GenStage

  require Logger

  defstruct [executor: nil,
             upstream: nil,
             first: true,
             done: false,
             error: nil,
             pipeline_id: nil,
             seq_id: nil,
             started: :os.timestamp(),
             mux: nil,
             topic: nil,
             relay: nil,
             relay_topic: nil,
             request: nil,
             invocation: nil,
             user: nil,
             permissions: nil,
             service_token: nil,
             buffer: []]

  @doc """
  Starts a stage to invoke a command

  ## Options
  * `:executor` - Pid of the executor responsible for the entire pipeline. Required.
  * `:upstream` - Pid of the preceding pipeline stage. Required.
  * `:pipeline_id` - Id of parent command pipeline. Required.
  * `:sequence_id` - Stage sequence id. Required.
  * `:multiplexer` - Pid of MQTT multiplexer assigned to the parent pipeline. Required.
  * `:request` - Original pipeline request submitted by user. Required.
  * `:invocation` - AST node representing the command invocation to execute. Required.
  * `:user` - Cog user model for the requesting user. Required.
  * `:permissions` - List of fully-qualified permission names granted to the user. Required.
  * `:service_token` - Token used to access Cog services. Optional.
  """
  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  def init(opts) do
    executor = Keyword.fetch!(opts, :executor)
    :erlang.monitor(:process, executor)
    upstream = Keyword.fetch!(opts, :upstream)
    pipeline_id = Keyword.fetch!(opts, :pipeline_id)
    seq_id = Keyword.fetch!(opts, :sequence_id)
    mux = Keyword.fetch!(opts, :multiplexer)
    topic = "bot/pipelines/#{pipeline_id}/#{seq_id}"
    request = Keyword.fetch!(opts, :request)
    invocation = Keyword.fetch!(opts, :invocation)
    user = Keyword.fetch!(opts, :user)
    perms = Keyword.fetch!(opts, :permissions)
    service_token = Keyword.get(opts, :service_token)
    state = %__MODULE__{executor: executor,
                        upstream: upstream,
                        pipeline_id: pipeline_id,
                        seq_id: seq_id,
                        mux: mux,
                        topic: topic,
                        request: request,
                        invocation: invocation,
                        user: user,
                        permissions: perms,
                        service_token: service_token}
    state = case pick_relay(state.invocation.meta.bundle_name, state.invocation.meta.version) do
              {:ok, relay} ->
                %{state | relay: relay, relay_topic: relay_topic(relay, state.invocation.meta)}
              error ->
                %{state | error: Signal.error(error)}
            end
    Multiplexer.subscribe(mux, state.topic)
    {:producer_consumer, state, subscribe_to: [upstream]}
  end

  # Ignore events if the stage is done
  def handle_events(_events, _from, %__MODULE__{done: true}=state) do
    {:noreply, [], state}
  end
  # Send error and then stop processing
  def handle_events(_events, _from, %__MODULE__{error: error}=state) when error != nil do
    {:noreply, [error, Signal.done()], %{state | done: true, error: nil}}
  end
  def handle_events(events, _from, state) do
    {events, state} = set_stream_positions(events, state)
    {outputs, state} = Enum.reduce_while(events, {[], state}, &process_signal/2)
    outputs = Enum.reverse(outputs)
    {:noreply, outputs, state}
  end

  def handle_info({:DOWN, _, :process, pid, _}, %__MODULE__{executor: executor}=state) when pid == executor do
    {:stop, :shutdown, state}
  end

  def terminate(reason, state) do
    Logger.debug("Invoke stage #{state.seq_id} for pipeline #{state.pipeline_id} stopped: #{inspect reason}")
  end

  defp set_stream_positions(events, %__MODULE__{first: true}=state) do
    {events, state} = set_first(events, state)
    maybe_set_last(events, state)
  end
  defp set_stream_positions(events, state) do
    maybe_set_last(events, state)
  end

  defp set_first(events, state) do
    [first|rest] = events
    events = [%{first | position: "first"}|rest]
    {events, %{state | first: false}}
  end

  defp maybe_set_last(events, state) do
    if Enum.count(events) < 2 do
      {events, state}
    else
      [last, next|rest] = Enum.reverse(events)
      if last.done == true do
        {Enum.reverse([last, %{next | position: "last"}|rest]), state}
      else
        {events, state}
      end
    end
  end

  defp process_signal(%Signal{}=signal, {accum, state}) do
    cond do
      Signal.done?(signal) ->
        {:halt, {[signal|accum], %{state | done: true}}}
      Signal.failed?(signal) ->
        {:halt, {[Signal.done(), signal], %{state | done: true}}}
      true ->
        case execute_signal(signal, state) do
          {:ok, nil, state} ->
            {:cont, {accum, state}}
          {:ok, signals, state} ->
            {:cont, {accum ++ signals, state}}
          {:error, reason, state} ->
            {:halt, {[Signal.done(), Signal.error(reason)], state}}
        end
    end
  end

  defp execute_signal(signal, state) do
    case verify_relay(state) do
      {:ok, state} ->
        case signal_to_request(signal, state) do
          {:ok, text, request} ->
            dispatch_event(text, request.cog_env, state.relay, state)
            Multiplexer.publish(state.mux, request, routed_by: state.relay_topic)
            topic = state.topic
            receive do
              {:publish, ^topic, message} ->
                process_response(CommandResponse.decode!(message), state)
            after 60000 ->
                {:error, {:error, :timeout}, state}
            end
        end
      error ->
        {:error, error, state}
    end
  end

  defp process_response(response, state) do
    bundle_version_id = state.invocation.meta.bundle_version_id
    case response.status do
      "ok" ->
        if response.body == nil do
          {:ok, nil, state}
        else
          if is_list(response.body) do
            {state, _, outputs} = Enum.reduce_while(response.body, {state, response, []}, &expand_output/2)
            {:ok, outputs, state}
          else
            {:ok, [Signal.wrap(response.body, bundle_version_id, response.template)], state}
          end
        end
      "abort" ->
        signals = [Signal.wrap(response.body, bundle_version_id, response.template), Signal.done()]
        {:ok, signals, state}
      "error" ->
        {:error, {:error, {:command_error, response}}, state}
    end
  end

  defp expand_output(item, {state, response, accum}) when is_map(item) do
    {:cont, {state, response, [Signal.wrap(item, state.invocation.meta.bundle_version_id, response.template)|accum]}}
  end
  defp expand_output(_item, {state, response, _accum}) do
    {:halt, {%{state|done: true}, response, [Signal.error({:error, :badmap})]}}
  end

  defp signal_to_request(signal, state) do
    perm_mode = Application.get_env(:cog, :access_rules, :enforcing)
    try do
      with {:ok, bound} <- Binder.bind(state.invocation, signal.data),
           {:ok, options, args} <- OptionInterpreter.initialize(bound),
           :allowed <- enforce_permissions(perm_mode, state.invocation.meta, options, args, state.permissions),
        do: {:ok, "#{bound}", %Cog.Messages.Command{command: state.invocation.meta.full_command_name,
                                        options: options,
                                        args: args,
                                        invocation_id: state.invocation.id,
                                        invocation_step: signal.position,
                                        # TODO: stuffing the provider into requestor here is a bit
                                        # code-smelly; investigate and fix
                                        requestor: state.request.sender |> Map.put_new("provider", state.request.room.provider),
                                        cog_env: signal.data,
                                        user: Cog.Models.EctoJson.render(state.user),
                                        room: state.request.room,
                                        reply_to:        state.topic,
                                        service_token:   state.service_token,
                                        services_root:   ServiceEndpoint.url()}}

    rescue
      e in BadValueError ->
        {:error, BadValueError.message(e)}
    end
  end

  defp enforce_permissions(:unenforcing, _meta, _options, _args, _permissions), do: :allowed
  defp enforce_permissions(:enforcing, meta, options, args, permissions) do
    PermissionInterpreter.check(meta, options, args, permissions)
  end
  defp enforce_permissions(unknown_mode, meta, options, args, permissions) do
    Logger.warn("Ignoring unknown :access_rules mode \"#{inspect unknown_mode}\".")
    enforce_permissions(:enforcing, meta, options, args, permissions)
  end

  defp verify_relay(state) do
    bundle_name = state.invocation.meta.bundle_name
    bundle_version = state.invocation.meta.version
    if Relays.relay_available?(state.relay, bundle_name, bundle_version) do
      {:ok, state}
    else
      case pick_relay(bundle_name, bundle_version) do
        {:ok, relay} ->
          {:ok, %{state | relay: relay, relay_topic: relay_topic(relay, state.invocation.meta)}}
        error ->
          error
      end
    end
  end

  defp pick_relay(bundle_name, bundle_version) do
    case Relays.pick_one(bundle_name, bundle_version) do
      # Store the selected relay in the relay cache
      {:ok, relay} ->
        {:ok, relay}
      error ->
      # Query DB to clarify error before reporting to the user
      if Cog.Repository.Bundles.assigned_to_group?(bundle_name) do
        error
      else
        {:error, {:no_relay_group, bundle_name}}
      end
    end
  end

  defp dispatch_event(text, cog_env, relay, state) do
    PipelineEvent.dispatched(state.pipeline_id, :timer.now_diff(:os.timestamp(), state.started),
                             text, relay, cog_env) |> Probe.notify
  end

  defp relay_topic(relay, meta) do
    "/bot/commands/#{relay}/#{meta.bundle_name}/#{meta.command_name}"
  end

end
