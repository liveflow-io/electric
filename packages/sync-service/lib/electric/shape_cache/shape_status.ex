defmodule Electric.ShapeCache.ShapeStatusBehaviour do
  @moduledoc """
  Behaviour defining the ShapeStatus functions to be used in mocks
  """
  alias Electric.Shapes.Shape
  alias Electric.ShapeCache.ShapeStatus
  alias Electric.Replication.LogOffset

  @type shape_handle() :: Electric.ShapeCacheBehaviour.shape_handle()
  @type xmin() :: Electric.ShapeCacheBehaviour.xmin()

  @callback initialise(ShapeStatus.options()) :: {:ok, ShapeStatus.t()} | {:error, term()}
  @callback list_shapes(ShapeStatus.t()) :: [{shape_handle(), Shape.t()}]
  @callback get_existing_shape(ShapeStatus.t(), Shape.t() | shape_handle()) ::
              {shape_handle(), LogOffset.t()} | nil
  @callback add_shape(ShapeStatus.t(), Shape.t()) ::
              {:ok, shape_handle()} | {:error, term()}
  @callback initialise_shape(ShapeStatus.t(), shape_handle(), xmin(), LogOffset.t()) ::
              :ok
  @callback set_snapshot_xmin(ShapeStatus.t(), shape_handle(), xmin()) :: :ok
  @callback set_latest_offset(ShapeStatus.t(), shape_handle(), LogOffset.t()) :: :ok
  @callback mark_snapshot_started(ShapeStatus.t(), shape_handle()) :: :ok
  @callback snapshot_started?(ShapeStatus.t(), shape_handle()) :: boolean()
  @callback remove_shape(ShapeStatus.t(), shape_handle()) ::
              {:ok, Shape.t()} | {:error, term()}
end

defmodule Electric.ShapeCache.ShapeStatus do
  @moduledoc """
  Keeps track of shape state.

  Can recover basic persisted shape metadata from shape storage to repopulate
  the in-memory cache.

  The shape cache then loads this and starts processes (storage and consumer)
  for each `{shape_handle, %Shape{}}` pair. These then use their attached storage
  to recover the status information for the shape (snapshot xmin and latest
  offset).

  The ETS metadata table name is part of the config because we need to be able
  to access the data in the ETS from anywhere, so there's an internal api,
  using the full state and an external api using just the table name.
  """
  alias Electric.Shapes.Shape
  alias Electric.ShapeCache.Storage
  alias Electric.Replication.LogOffset

  require Logger

  @behaviour Electric.ShapeCache.ShapeStatusBehaviour

  @schema NimbleOptions.new!(
            shape_meta_table: [type: {:or, [:atom, :reference]}, required: true],
            storage: [type: :mod_arg, required: true],
            root: [type: :string, default: "./shape_cache"]
          )

  defstruct [:root, :shape_meta_table, :storage]

  @type shape_handle() :: Electric.ShapeCacheBehaviour.shape_handle()
  @type xmin() :: Electric.ShapeCacheBehaviour.xmin()
  @type table() :: atom() | reference()
  @type t() :: %__MODULE__{
          root: String.t(),
          storage: Storage.storage(),
          shape_meta_table: table()
        }
  @type option() :: unquote(NimbleOptions.option_typespec(@schema))
  @type options() :: [option()]

  @shape_meta_data :shape_meta_data
  @shape_hash_lookup :shape_hash_lookup
  @shape_relation_lookup :shape_relation_lookup
  @shape_meta_shape_pos 2
  @shape_meta_xmin_pos 3
  @shape_meta_latest_offset_pos 4
  @shape_meta_last_read_pos 5
  @snapshot_started :snapshot_started

  @impl true
  def initialise(opts) do
    with {:ok, config} <- NimbleOptions.validate(opts, @schema),
         {:ok, meta_table} = Access.fetch(config, :shape_meta_table),
         {:ok, storage} = Access.fetch(config, :storage) do
      state =
        struct(
          __MODULE__,
          Keyword.merge(config,
            shape_meta_table: meta_table,
            storage: storage
          )
        )

      load(state)
    end
  end

  @impl true
  def add_shape(state, shape) do
    {_, shape_handle} = Shape.generate_id(shape)
    # For fresh snapshots we're setting "latest" offset to be a highest possible virtual offset,
    # which is needed because while the snapshot is being made we DON'T update this ETS table.
    # We could, but that would required making the Storage know about this module and I don't like that.
    offset = LogOffset.last_before_real_offsets()

    true =
      :ets.insert_new(
        state.shape_meta_table,
        [
          {{@shape_hash_lookup, Shape.comparable(shape)}, shape_handle},
          {{@shape_meta_data, shape_handle}, shape, nil, offset,
           :erlang.monotonic_time(:microsecond)}
          | Enum.map(Shape.list_relations(shape), fn {oid, _name} ->
              {{@shape_relation_lookup, oid, shape_handle}, true}
            end)
        ]
      )

    {:ok, shape_handle}
  end

  @impl true
  def list_shapes(state) do
    :ets.select(state.shape_meta_table, [
      {
        {{@shape_meta_data, :"$1"}, :"$2", :_, :_, :_},
        [true],
        [{{:"$1", :"$2"}}]
      }
    ])
  end

  @spec list_shape_handles_for_relations(t(), list(Electric.oid_relation())) :: [
          shape_handle()
        ]
  def list_shape_handles_for_relations(state, relations) do
    relations
    |> Enum.map(fn {oid, _} -> {{@shape_relation_lookup, oid, :"$1"}, :_} end)
    |> Enum.map(fn match -> {match, [true], [:"$1"]} end)
    |> then(&:ets.select(state.shape_meta_table, &1))
  end

  @impl true
  def remove_shape(state, shape_handle) do
    try do
      shape =
        :ets.lookup_element(
          state.shape_meta_table,
          {@shape_meta_data, shape_handle},
          @shape_meta_shape_pos
        )

      :ets.select_delete(
        state.shape_meta_table,
        [
          {{{@shape_meta_data, shape_handle}, :_, :_, :_, :_}, [], [true]},
          {{{@shape_hash_lookup, Shape.comparable(shape)}, shape_handle}, [], [true]},
          {{{@snapshot_started, shape_handle}, :_}, [], [true]}
          | Enum.map(Shape.list_relations(shape), fn {oid, _} ->
              {{{@shape_relation_lookup, oid, shape_handle}, :_}, [], [true]}
            end)
        ]
      )

      {:ok, shape}
    rescue
      # Sometimes we're calling cleanup when snapshot creation has failed for
      # some reason. In those cases we're not sure about the state of the ETS
      # keys, so we're doing our best to just delete everything without
      # crashing
      ArgumentError ->
        {:error, "No shape matching #{inspect(shape_handle)}"}
    end
  end

  @impl true
  def get_existing_shape(%__MODULE__{shape_meta_table: table}, shape_or_id) do
    get_existing_shape(table, shape_or_id)
  end

  def get_existing_shape(meta_table, %Shape{} = shape) do
    case :ets.lookup_element(meta_table, {@shape_hash_lookup, Shape.comparable(shape)}, 2, nil) do
      nil ->
        nil

      shape_handle when is_binary(shape_handle) ->
        try do
          {shape_handle, latest_offset!(meta_table, shape_handle)}
        rescue
          ArgumentError ->
            nil
        end
    end
  end

  def get_existing_shape(meta_table, shape_handle) when is_binary(shape_handle) do
    case :ets.lookup(meta_table, {@shape_meta_data, shape_handle}) do
      [] -> nil
      [{_, _shape, _xmin, offset, _}] -> {shape_handle, offset}
    end
  end

  @impl true
  def initialise_shape(state, shape_handle, snapshot_xmin, latest_offset) do
    true =
      :ets.update_element(state.shape_meta_table, {@shape_meta_data, shape_handle}, [
        {@shape_meta_xmin_pos, snapshot_xmin},
        {@shape_meta_latest_offset_pos, latest_offset}
      ])

    :ok
  end

  @impl true
  def set_snapshot_xmin(state, shape_handle, snapshot_xmin) do
    :ets.update_element(state.shape_meta_table, {@shape_meta_data, shape_handle}, [
      {@shape_meta_xmin_pos, snapshot_xmin}
    ])

    :ok
  end

  @impl true
  def set_latest_offset(
        %__MODULE__{shape_meta_table: table} = _state,
        shape_handle,
        latest_offset
      ) do
    set_latest_offset(table, shape_handle, latest_offset)
  end

  def set_latest_offset(meta_table, shape_handle, latest_offset) do
    :ets.update_element(meta_table, {@shape_meta_data, shape_handle}, [
      {@shape_meta_latest_offset_pos, latest_offset}
    ])

    :ok
  end

  def update_last_read_time_to_now(%__MODULE__{shape_meta_table: meta_table}, shape_handle) do
    update_last_read_time_to_now(meta_table, shape_handle)
  end

  def update_last_read_time_to_now(meta_table, shape_handle) do
    :ets.update_element(meta_table, {@shape_meta_data, shape_handle}, [
      {@shape_meta_last_read_pos, :erlang.monotonic_time(:microsecond)}
    ])
  end

  def least_recently_used(%__MODULE__{shape_meta_table: meta_table}, shape_count) do
    least_recently_used(meta_table, shape_count)
  end

  @microseconds_in_a_minute 60 * 1000 * 1000
  def least_recently_used(meta_table, shape_count) do
    :ets.select(meta_table, [
      {
        {{@shape_meta_data, :"$1"}, :_, :_, :_, :"$2"},
        [true],
        [{{:"$1", :"$2"}}]
      }
    ])
    |> Enum.sort_by(fn {_, last_read} -> last_read end)
    |> Stream.map(fn {handle, last_read} ->
      %{
        shape_handle: handle,
        elapsed_minutes_since_use:
          (:erlang.monotonic_time(:microsecond) - last_read) / @microseconds_in_a_minute
      }
    end)
    |> Enum.take(shape_count)
  end

  def latest_offset!(%__MODULE__{shape_meta_table: table} = _state, shape_handle) do
    latest_offset(table, shape_handle)
  end

  def latest_offset!(meta_table, shape_handle) do
    :ets.lookup_element(
      meta_table,
      {@shape_meta_data, shape_handle},
      @shape_meta_latest_offset_pos
    )
  end

  def latest_offset(%__MODULE__{shape_meta_table: table} = _state, shape_handle) do
    latest_offset(table, shape_handle)
  end

  def latest_offset(meta_table, shape_handle) do
    turn_raise_into_error(fn ->
      :ets.lookup_element(
        meta_table,
        {@shape_meta_data, shape_handle},
        @shape_meta_latest_offset_pos
      )
    end)
  end

  def snapshot_xmin(%__MODULE__{shape_meta_table: table} = _state, shape_handle) do
    snapshot_xmin(table, shape_handle)
  end

  def snapshot_xmin(meta_table, shape_handle)
      when is_reference(meta_table) or is_atom(meta_table) do
    turn_raise_into_error(fn ->
      :ets.lookup_element(
        meta_table,
        {@shape_meta_data, shape_handle},
        @shape_meta_xmin_pos
      )
    end)
  end

  @impl true
  def snapshot_started?(%__MODULE__{shape_meta_table: table} = _state, shape_handle) do
    snapshot_started?(table, shape_handle)
  end

  def snapshot_started?(meta_table, shape_handle) do
    case :ets.lookup(meta_table, {@snapshot_started, shape_handle}) do
      [] -> false
      [{{@snapshot_started, ^shape_handle}, true}] -> true
    end
  end

  @impl true
  def mark_snapshot_started(%__MODULE__{shape_meta_table: table} = _state, shape_handle) do
    :ets.insert(table, {{@snapshot_started, shape_handle}, true})
    :ok
  end

  defp load(state) do
    with {:ok, shapes} <- Storage.get_all_stored_shapes(state.storage) do
      :ets.insert(
        state.shape_meta_table,
        Enum.concat([
          Enum.flat_map(shapes, fn {shape_handle, shape} ->
            relations = Shape.list_relations(shape)

            [
              {{@shape_hash_lookup, Shape.comparable(shape)}, shape_handle},
              {{@shape_meta_data, shape_handle}, shape, nil, LogOffset.first(),
               :erlang.monotonic_time(:microsecond)}
              | Enum.map(relations, fn {oid, _} ->
                  {{@shape_relation_lookup, oid, shape_handle}, true}
                end)
            ]
          end)
        ])
      )

      {:ok, state}
    end
  end

  defp turn_raise_into_error(fun) do
    try do
      {:ok, fun.()}
    rescue
      ArgumentError ->
        :error
    end
  end
end
