defmodule Cog.Command.Pipeline2.InvokeStage do

  alias Experimental.GenStage

  alias Carrier.Messaging.Multiplexer
  alias Cog.Command.{OptionInterpreter, PermissionInterpreter}
  alias Cog.Command.Pipeline.{Binder, Plan}
  alias Cog.Command.Pipeline2.Signal
  alias Cog.Events.PipelineEvent
  alias Cog.Messages.CommandResponse
  alias Cog.Relay.Relays
  alias Cog.ServiceEndpoint
  alias Piper.Command.Ast.BadValueError

  use GenStage

  require Logger

  defstruct [
    upstream: nil,
    done: false,
    pipeline_id: nil,
    seq_id: nil,
    started: :erlang.timestamp(),
    mux: nil,
    topic: nil,
    relays: %{},
    request: nil,
    invocation: nil,
    user: nil,
    permissions: nil,
    service_token: nil
  ]


  @doc """
  Starts a stage to invoke a command

  ## Options
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
    GenStage.start_link(__MODULE__, [opts])
  end

  def init([opts]) do
    upstream = Keyword.fetch!(opts, :upstream)
    pipeline_id = Keyword.fetch!(opts, :pipeline_id)
    seq_id = Keyword.fetch!(opts, :sequence_id)
    mux = Keyword.fetch!(opts, :multiplexer)
    request = Keyword.fetch!(opts, :request)
    invocation = Keyword.fetch!(opts, :invocation)
    user = Keyword.fetch!(opts, :user)
    perms = Keyword.fetch!(opts, :permissions)
    service_token = Keyword.get(opts, :service_token)
    topic = "bot/pipelines/#{pipeline_id}/#{seq_id}"
    Multiplexer.subscribe(mux, topic)
    {:producer_consumer, %__MODULE__{upstream: upstream,
                                     pipeline_id: pipeline_id,
                                     seq_id: seq_id,
                                     mux: mux,
                                     topic: topic,
                                     request: request,
                                     invocation: invocation,
                                     user: user,
                                     permissions: perms,
                                     service_token: service_token}, subscribe_to: [upstream]}
  end

  # Ignore events if the stage is done
  def handle_events(_events, _from, %__MODULE__{done: true}=state) do
    {:noreply, [], state}
  end
  def handle_events(events, _from, state) do
    {outputs, state} = Enum.reduce_while(events, {[], state}, &process_signal/2)
    {:noreply, Enum.reverse(outputs), state}
  end

  defp process_signal(%Signal{}=signal, {accum, state}) do
    cond do
      Signal.done?(signal) ->
        {:halt, {[signal|accum], %{state | done: true}}}
      Signal.failed?(signal) ->
        {:halt, {[signal|accum], %{state | done: true}}}
      true ->
        case execute_signal(signal, state) do
          {:ok, nil, state} ->
            {:cont, {accum, state}}
          {:ok, signals, state} ->
            {:cont, {accum ++ signals, state}}
          {:error, reason, state} ->
            {:halt, {[Signal.error(reason)], state}}
        end
    end
  end

  defp execute_signal(signal, state) do
    case plan_execution(signal, state) do
      {:ok, plan} ->
        bundle_name  = plan.parser_meta.bundle_name
        bundle_version = plan.parser_meta.version
        command_name = plan.parser_meta.command_name
        case assign_relay(state.relays, bundle_name, bundle_version) do
          {:error, reason} ->
            {:error, reason, state}
          {:ok, {relay, relays}} ->
            state = %{state | relays: relays}
            topic = state.topic
            relay_topic = "/bot/commands/#{relay}/#{bundle_name}/#{command_name}"
            req = request_for_plan(plan, state.request, state.user, topic, state.service_token)
            dispatch_event(plan, relay, state)
            Multiplexer.publish(state.mux, req, routed_by: relay_topic)
            receive do
              {:publish, ^topic, message} ->
                process_response(CommandResponse.decode!(message), state)
            after 60000 ->
                {:error, :timeout, state}
            end
        end
      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp process_response(response, state) do
    bundle_version_id = state.invocation.meta.bundle_version_id
    case response.status do
      "ok" ->
        if response.body == nil do
          {:ok, nil, state}
        else
          {:ok, [Signal.wrap(response.body, bundle_version_id, response.template)], state}
        end
      "abort" ->
        signals = [Signal.wrap(response.body, bundle_version_id, response.template), Signal.done()]
        {:ok, signals, state}
      "error" ->
        {:error, {:command_error, response}, state}
    end
  end

  defp plan_execution(signal, state) do
    perm_mode = Application.get_env(:cog, :access_rules, :enforcing)
    try do
      with {:ok, bound} <- Binder.bind(state.invocation, signal.data),
           {:ok, options, args} <- OptionInterpreter.initialize(bound),
           :allowed <- enforce_permissions(perm_mode, state.invocation.meta, options, args, state.permissions),
        do: {:ok, %Plan{parser_meta: state.invocation.meta,
                        options: options,
                        args: args,
                        cog_env: signal.data,
                        invocation_id: state.invocation.id,
                        invocation_text: to_string(bound)}}
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

  defp request_for_plan(plan, request, user, reply_to, service_token) do
    # TODO: stuffing the provider into requestor here is a bit
    # code-smelly; investigate and fix
    provider  = request.adapter
    requestor = request.sender |> Map.put_new("provider", provider)
    room      = request.room
    user      = Cog.Models.EctoJson.render(user)

    %Cog.Messages.Command{
      command:         plan.parser_meta.full_command_name,
      options:         plan.options,
      args:            plan.args,
      cog_env:         plan.cog_env,
      invocation_id:   plan.invocation_id,
      invocation_step: plan.invocation_step,
      requestor:       requestor,
      user:            user,
      room:            room,
      reply_to:        reply_to,
      service_token:   service_token,
      services_root:   ServiceEndpoint.url()
    }
  end

  defp assign_relay(relays, bundle_name, bundle_version) do
    case Map.get(relays, bundle_name) do
      # No assignment so let's pick one
      nil ->
        case Relays.pick_one(bundle_name, bundle_version) do
          # Store the selected relay in the relay cache
          {:ok, relay} ->
            {:ok, {relay, Map.put(relays, bundle_name, relay)}}
          error ->
            # Query DB to clarify error before reporting to the user
            if Cog.Repository.Bundles.assigned_to_group?(bundle_name) do
              error
            else
              {:error, :no_relay_group}
            end
        end
      # Relay was previously assigned
      relay ->
        # Is the bundle still available on the relay? If not, remove the current assignment from the cache
        # and select a new relay
        if Relays.relay_available?(relay, bundle_name, bundle_version) do
          {:ok, {relay, relays}}
        else
          relays = Map.delete(relays, bundle_name)
          assign_relay(relays, bundle_name, bundle_version)
        end
    end
  end

  defp dispatch_event(plan, relay, state) do
    PipelineEvent.dispatched(state.pipeline_id, :timer.now_diff(:os.timestamp(), state.started),
                             plan.invocation_text, relay, plan.cog_env)
    |> Probe.notify
  end

end
