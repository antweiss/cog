defmodule Cog.Command.Pipeline2.Signal do

  defstruct [
    data: nil,
    bundle_version_id: nil,
    template: nil,
    position: nil,
    done: false,
    failed: false,
  ]

  def done, do: %__MODULE__{done: true}

  def error(error), do: %__MODULE__{data: error, failed: true}

  def wrap(data), do: %__MODULE__{data: data}

  def wrap(data, version_id, template), do: %__MODULE__{data: data, bundle_version_id: version_id, template: template}

  def done?(%__MODULE__{}=signal) do
    signal.done
  end

  def failed?(%__MODULE__{}=signal) do
    signal.failed
  end

end
