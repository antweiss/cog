defmodule Carrier.Messaging.Multiplexer do

  alias Carrier.Messaging.Connection

  use GenServer

  defstruct [
    conn: nil,
    subscriptions: %{}
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [opts])
  end

  def subscribe(mux, topic, caller \\ self()) do
    GenServer.call(mux, {:subscribe, topic, caller}, :infinity)
  end

  def publish(mux, %{__struct__: _} = message, kw_args) do
    GenServer.call(mux, {:publish, message, kw_args}, :infinity)
  end

  def disconnect(mux) do
    GenServer.cast(mux, :disconnect)
  end

  def init([opts]) do
    case Connection.connect(opts) do
      {:ok, conn} ->
        {:ok, %__MODULE__{conn: conn}}
      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_call({:subscribe, topic, caller}, _from, state) do
    Connection.subscribe(state.conn, topic)
    {:reply, :ok, %{state | subscriptions: Map.update(state.subscriptions, topic, [caller], &([caller|&1]))}}
  end

  def handle_call({:publish, message, kw_args}, _from, state) do
    result = Connection.publish(state.conn, message, kw_args)
    {:reply, result, state}
  end

  def handle_cast(:disconnect, state) do
    {:stop, :normal, state}
  end

  def handle_info({:publish, topic, _}=message, state) do
    case Map.get(state.subscriptions, topic) do
      nil ->
        :ok
      subscribers ->
        Enum.each(subscribers, &(Process.send(&1, message, [])))
    end
    {:noreply, state}
  end

end
