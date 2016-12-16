defmodule Cog.Command.Pipeline2.Executor do

  use GenServer

  alias Carrier.Messaging.MultiplexerSup
  alias Cog.Chat.Adapter, as: ChatAdapter
  alias Cog.Command.{CommandResolver, PermissionsCache, ReplyHelper}
  alias Cog.Command.Pipeline.Destination
  alias Cog.Command.Pipeline2.{InitiatorSup, InvokeSup, TerminatorSup}
  alias Cog.Messages.AdapterRequest
  alias Cog.Queries
  alias Cog.Repo
  alias Piper.Command.Ast
  alias Piper.Command.Parser
  alias Piper.Command.ParserOptions

  require Logger

  defstruct [
    mux: nil,
    request: nil,
    stages: [],
    terminator: nil,
    user: nil,
    permissions: nil,
    service_token: nil,
    command_timeout: nil
  ]

  def start_link(%AdapterRequest{}=request) do
    GenServer.start_link(__MODULE__, [request])
  end

  def run(executor) do
    GenServer.call(executor, :run, :infinity)
  end

  def deliver_results(executor, results) do
    GenServer.cast(executor, {:deliver_results, results})
  end

  def init([request]) do
    config = Application.fetch_env!(:cog, Cog.Command.Pipeline)
    request = sanitize_request(request)
    service_token = Cog.Command.Service.Tokens.new
    {:ok, mux} = MultiplexerSup.connect()
    case fetch_user_from_request(request) do
      {:ok, user} ->
        {:ok, perms} = PermissionsCache.fetch(user)
        command_timeout = get_command_timeout(request.adapter, config)
        state = %__MODULE__{request: request,
                            mux: mux,
                            user: user,
                            service_token: service_token,
                            permissions: perms,
                            command_timeout: command_timeout}
        {:ok, state}
      {:error, :not_found} ->
        ReplyHelper.send("unregistered-user",
          unregistered_user_data(request),
          request.room,
          request.adapter,
          mux)
        :ignore
    end
  end

  def handle_call(:run, _from, state) do
    case parse(state) do
      {:ok, pipeline, destinations, state} ->
        {:ok, initial_context} = create_initial_context(state.request)
        {:ok, initiator} = InitiatorSup.create(inputs: initial_context)
        stages = pipeline
                 |> Enum.with_index
                 |> Enum.reduce([initiator], &(create_invoke_stage(&1, &2, state)))
        {:reply, :ok, %{state | stages: terminate_pipeline(stages, destinations)}}
      error ->
        {:reply, error, state}
    end
  end

  def handle_cast({:deliver_results, results}, state) do
    IO.puts "Results: #{inspect results, pretty: true}"
    {:noreply, state}
  end

  defp terminate_pipeline([upstream|_]=stages, destinations) do
    opts = [upstream: upstream,
            destinations: destinations,
            executor: self()]
    {:ok, terminator} = TerminatorSup.create(opts)
    [terminator|stages]
  end

  defp create_invoke_stage({invocation, index}, [upstream|_]=accum, state) do
    opts = [upstream: upstream, pipeline_id: state.request.id,
            sequence_id: index, multiplexer: state.mux,
            request: state.request, invocation: invocation,
            user: state.user, permissions: state.permissions,
            service_token: state.service_token]
    {:ok, invoke} = InvokeSup.create(opts)
    [invoke|accum]
  end

  defp sanitize_request(%Cog.Messages.AdapterRequest{text: text}=request) do
    prefix = Application.get_env(:cog, :command_prefix, "!")

    text = text
    |> String.replace(~r/^#{Regex.escape(prefix)}/, "") # Remove command prefix
    |> String.replace(~r/“|”/, "\"")      # Replace OS X's smart quotes and dashes with ascii equivalent
    |> String.replace(~r/‘|’/, "'")
    |> String.replace(~r/—/, "--")
    |> HtmlEntities.decode                # Decode html entities

    # TODO: Fold this into decoding of the request initially?
    %{request | text: text}
  end

  defp fetch_user_from_request(%Cog.Messages.AdapterRequest{}=request) do
    # TODO: This should happen when we validate the request
    if ChatAdapter.is_chat_provider?(request.adapter) do
      adapter   = request.adapter
      sender_id = request.sender.id

      user = Queries.User.for_chat_provider_user_id(sender_id, adapter)
      |> Repo.one

      case user do
        nil ->
          {:error, :not_found}
        user ->
          {:ok, user}
      end
    else
      cog_name = request.sender.id
      case Repo.get_by(Cog.Models.User, username: cog_name) do
        %Cog.Models.User{}=user ->
          {:ok, user}
        nil ->
          {:error, :not_found}
      end
    end
  end

  defp get_command_timeout(adapter, config) do
    if ChatAdapter.is_chat_provider?(adapter) do
      Keyword.fetch!(config, :interactive_timeout)
    else
      Keyword.fetch!(config, :trigger_timeout)
    end
    |> Cog.Config.convert(:ms)
  end

  defp unregistered_user_data(request) do
    handle   = request.sender.handle
    creators = user_creator_handles(request)

    {:ok, mention_name} = Cog.Chat.Adapter.mention_name(request.adapter, handle)
    {:ok, display_name} = Cog.Chat.Adapter.display_name(request.adapter)

    %{"handle" => handle,
      "mention_name" => mention_name,
      "display_name" => display_name,
      "user_creators" => creators}
  end

  # Returns a list of adapter-appropriate "mention names" of all Cog
  # users with registered handles for the adapter that currently have
  # the permissions required to create and manipulate new Cog user
  # accounts.
  #
  # The intention is to create a list of people that can assist
  # immediately in-chat when unregistered users attempt to interact
  # with Cog. Not every Cog user with these permissions will
  # necessarily have a chat handle registered for the chat provider
  # being used (most notably, the bootstrap admin user).
  defp user_creator_handles(request) do
    provider = request.adapter

    "operable:manage_users"
    |> Cog.Queries.Permission.from_full_name
    |> Cog.Repo.one!
    |> Cog.Queries.User.with_permission
    |> Cog.Queries.User.for_chat_provider(provider)
    |> Cog.Repo.all
    |> Enum.flat_map(&(&1.chat_handles))
    |> Enum.map(fn(h) ->
      {:ok, mention} = Cog.Chat.Adapter.mention_name(provider, h.handle)
      mention
    end)
    |> Enum.sort
  end

  ########################################################################
  # Context Manipulation Functions

  # Each command in a pipeline has access to a "Cog Env", which is the
  # accumulated output of the execution of the pipeline thus far. This
  # is used as a binding context, as well as an input source for the
  # commands.
  #
  # The first command in a pipeline is different, though, as there is
  # no previous input. However, pipelines triggered by external events
  # (e.g., webhooks) can set the initial context to be, e.g., the body
  # of the HTTP request that triggered the pipeline.
  #
  # In the absence of an explicit initial context, a single empty map
  # is used. This provides an empty binding context for the first
  # command, preventing the use of unbound variables in the first
  # invocation of a pipeline. (For external-event initiated pipelines
  # with initial contexts, there can be variables in the first
  # invocation).
  #
  # In general, chat-adapter initiated pipelines will not be supplied
  # with an initial context.
  defp create_initial_context(%Cog.Messages.AdapterRequest{}=request) do
    context = List.wrap(request.initial_context)

    if Enum.all?(context, &is_map/1) do
      {:ok, context}
    else
      :error
    end
  end

  defp parse(state) do
    options = %ParserOptions{resolver: CommandResolver.command_resolver_fn(state.user)}
    case Parser.scan_and_parse(state.request.text, options) do
      {:ok, %Ast.Pipeline{}=pipeline} ->
        case Destination.process(Ast.Pipeline.redirect_targets(pipeline),
                                 state.request.sender,
                                 state.request.room,
                                 state.request.adapter) do
          {:ok, destinations} ->
            {:ok, pipeline, destinations, state}
          {:error, invalid} ->
            {:error, {:redirect_error, invalid}, state}
        end
      {:error, msg} ->
        {:error, {:parse_error, msg}, state}
    end
  end

end
