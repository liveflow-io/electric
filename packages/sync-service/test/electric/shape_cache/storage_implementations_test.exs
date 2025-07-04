defmodule Electric.ShapeCache.StorageImplimentationsTest do
  use ExUnit.Case, async: true
  use Repatch.ExUnit

  alias Electric.Shapes.Shape
  alias Electric.ShapeCache.Storage
  alias Electric.ShapeCache.FileStorage
  alias Electric.Postgres.Lsn
  alias Electric.Replication.LogOffset
  alias Electric.Replication.Changes
  alias Electric.ShapeCache.InMemoryStorage
  alias Electric.Utils

  import Support.ComponentSetup
  import Support.TestUtils

  @moduletag :tmp_dir

  @shape_handle "the-shape-handle"
  @shape %Shape{
    root_table: {"public", "items"},
    root_table_id: 1,
    root_pk: ["id"],
    selected_columns: ["id"],
    where:
      Electric.Replication.Eval.Parser.parse_and_validate_expression!("id != '1'",
        refs: %{["id"] => :text}
      )
  }

  @snapshot_offset LogOffset.first()
  @snapshot_offset_encoded to_string(@snapshot_offset)
  @data_stream [
                 %{
                   offset: @snapshot_offset,
                   value: %{id: "00000000-0000-0000-0000-000000000001", title: "row1"},
                   key: ~S|"public"."the-table"/"00000000-0000-0000-0000-000000000001"|,
                   headers: %{operation: "insert"}
                 },
                 %{
                   offset: @snapshot_offset,
                   value: %{id: "00000000-0000-0000-0000-000000000002", title: "row2"},
                   key: ~S|"public"."the-table"/"00000000-0000-0000-0000-000000000002"|,
                   headers: %{operation: "insert"}
                 }
               ]
               |> Enum.map(&Jason.encode_to_iodata!/1)

  setup :with_stack_id_from_test

  for module <- [InMemoryStorage, FileStorage] do
    module_name = module |> Module.split() |> List.last()

    doctest module, import: true

    describe "#{module_name}.snapshot_started?/2" do
      setup do
        {:ok, %{module: unquote(module)}}
      end

      setup :start_storage

      test "returns false when shape does not exist", %{module: storage, opts: opts} do
        assert storage.snapshot_started?(opts) == false
      end

      test "returns true when snapshot has started", %{module: storage, opts: opts} do
        storage.mark_snapshot_as_started(opts)

        assert storage.snapshot_started?(opts) == true
      end
    end

    describe "#{module_name}.append_to_log!/3" do
      setup do
        {:ok, %{module: unquote(module)}}
      end

      setup :start_storage
      setup :start_empty_snapshot

      test "adds items to the log", %{module: storage, opts: opts} do
        lsn = Lsn.from_integer(1000)
        offset = LogOffset.new(lsn, 0)

        log_items =
          [
            %Changes.NewRecord{
              relation: {"public", "test_table"},
              record: %{"id" => "123", "name" => "Test"},
              log_offset: offset
            }
          ]
          |> changes_to_log_items()

        storage.append_to_log!(log_items, opts)

        stream = storage.get_log_stream(LogOffset.first(), LogOffset.last(), opts)

        assert [
                 %{
                   key: ~S|"public"."test_table"/"123"|,
                   value: %{id: "123", name: "Test"},
                   headers: %{
                     operation: "insert",
                     txids: [1],
                     relation: ["public", "test_table"],
                     lsn: "1000",
                     op_position: 0
                   }
                 }
               ] == Enum.map(stream, &Jason.decode!(&1, keys: :atoms))
      end

      test "adds items to the log in idempotent way", %{module: storage, opts: opts} do
        lsn = Lsn.from_integer(1000)
        offset = LogOffset.new(lsn, 0)

        log_items =
          [
            %Changes.NewRecord{
              relation: {"public", "test_table"},
              record: %{"id" => "123", "name" => "Test"},
              log_offset: offset
            }
          ]
          |> changes_to_log_items()

        :ok = storage.append_to_log!(log_items, opts)

        log1 =
          storage.get_log_stream(LogOffset.first(), LogOffset.last(), opts)
          |> Enum.map(&:json.decode/1)

        :ok = storage.append_to_log!(log_items, opts)

        log2 =
          storage.get_log_stream(LogOffset.first(), LogOffset.last(), opts)
          |> Enum.map(&:json.decode/1)

        assert log1 == log2
      end
    end

    describe "#{module_name}.get_log_stream/4 for appended txns" do
      setup do
        {:ok, %{module: unquote(module)}}
      end

      setup :start_storage
      setup :start_empty_snapshot

      test "returns correct stream of log items", %{storage: opts} do
        lsn1 = Lsn.from_integer(1000)
        lsn2 = Lsn.from_integer(2000)

        log_items1 =
          [
            %Changes.NewRecord{
              relation: {"public", "test_table"},
              record: %{"id" => "123", "name" => "Test1"},
              log_offset: LogOffset.new(lsn1, 0)
            }
          ]
          |> changes_to_log_items()

        log_items2 =
          [
            %Changes.UpdatedRecord{
              relation: {"public", "test_table"},
              old_record: %{"id" => "123", "name" => "Test1"},
              record: %{"id" => "123", "name" => "Test2"},
              log_offset: LogOffset.new(lsn2, 0)
            },
            %Changes.DeletedRecord{
              relation: {"public", "test_table"},
              old_record: %{"id" => "123", "name" => "Test1"},
              log_offset: LogOffset.new(lsn2, 1)
            }
          ]
          |> changes_to_log_items()

        :ok = Storage.append_to_log!(log_items1, opts)
        :ok = Storage.append_to_log!(log_items2, opts)

        stream = Storage.get_log_stream(LogOffset.first(), LogOffset.last(), opts)
        entries = Enum.map(stream, &Jason.decode!(&1, keys: :atoms))

        assert [
                 %{headers: %{operation: "insert"}},
                 %{headers: %{operation: "update"}},
                 %{headers: %{operation: "delete"}}
               ] = entries
      end

      test "returns stream of log items after offset", %{module: storage, opts: opts} do
        lsn1 = Lsn.from_integer(1000)
        lsn2 = Lsn.from_integer(2000)

        log_items1 =
          [
            %Changes.NewRecord{
              relation: {"public", "test_table"},
              record: %{"id" => "123", "name" => "Test1"},
              log_offset: LogOffset.new(lsn1, 0)
            }
          ]
          |> changes_to_log_items()

        log_items2 =
          [
            %Changes.UpdatedRecord{
              relation: {"public", "test_table"},
              old_record: %{"id" => "123", "name" => "Test1"},
              record: %{"id" => "123", "name" => "Test2"},
              log_offset: LogOffset.new(lsn2, 0)
            },
            %Changes.DeletedRecord{
              relation: {"public", "test_table"},
              old_record: %{"id" => "123", "name" => "Test1"},
              log_offset: LogOffset.new(lsn2, 1)
            }
          ]
          |> changes_to_log_items()

        :ok = storage.append_to_log!(log_items1, opts)
        :ok = storage.append_to_log!(log_items2, opts)

        stream =
          storage.get_log_stream(LogOffset.new(lsn1, 0), LogOffset.last(), opts)

        entries = Enum.map(stream, &Jason.decode!(&1, keys: :atoms))

        assert [
                 %{headers: %{operation: "update"}},
                 %{headers: %{operation: "delete"}}
               ] = entries
      end

      test "returns stream of log items after offset and before max_offset (inclusive)", %{
        module: storage,
        opts: opts
      } do
        lsn1 = Lsn.from_integer(1000)
        lsn2 = Lsn.from_integer(2000)

        log_items1 =
          [
            %Changes.NewRecord{
              relation: {"public", "test_table"},
              record: %{"id" => "123", "name" => "Test1"},
              log_offset: LogOffset.new(lsn1, 0)
            }
          ]
          |> changes_to_log_items()

        log_items2 =
          [
            %Changes.UpdatedRecord{
              relation: {"public", "test_table"},
              old_record: %{"id" => "123", "name" => "Test1"},
              record: %{"id" => "123", "name" => "Test2"},
              log_offset: LogOffset.new(lsn2, 0)
            },
            %Changes.DeletedRecord{
              relation: {"public", "test_table"},
              old_record: %{"id" => "123", "name" => "Test1"},
              log_offset: LogOffset.new(lsn2, 1)
            }
          ]
          |> changes_to_log_items()

        :ok = storage.append_to_log!(log_items1, opts)
        :ok = storage.append_to_log!(log_items2, opts)

        stream =
          storage.get_log_stream(
            LogOffset.new(lsn1, 0),
            LogOffset.new(lsn2, 0),
            opts
          )

        entries = Enum.map(stream, &Jason.decode!(&1, keys: :atoms))

        assert [%{headers: %{operation: "update"}}] = entries
      end
    end

    describe "#{module_name}.get_log_stream/4 for snapshots" do
      setup do
        {:ok, %{module: unquote(module)}}
      end

      setup :start_storage

      test "returns snapshot when shape does exist", %{storage: opts} do
        Storage.mark_snapshot_as_started(opts)
        Storage.make_new_snapshot!(@data_stream, opts)

        stream =
          Storage.get_log_stream(LogOffset.before_all(), LogOffset.new(0, 0), opts)

        assert [
                 %{
                   offset: @snapshot_offset_encoded,
                   value: %{id: "00000000-0000-0000-0000-000000000001", title: "row1"},
                   key: ~S|"public"."the-table"/"00000000-0000-0000-0000-000000000001"|,
                   headers: %{operation: "insert"}
                 },
                 %{
                   offset: @snapshot_offset_encoded,
                   value: %{id: "00000000-0000-0000-0000-000000000002", title: "row2"},
                   key: ~S|"public"."the-table"/"00000000-0000-0000-0000-000000000002"|,
                   headers: %{operation: "insert"}
                 }
               ] = Enum.map(stream, &Jason.decode!(&1, keys: :atoms))
      end

      test "does not return items not in the snapshot", %{storage: opts} do
        log_items =
          [
            %Changes.NewRecord{
              relation: {"public", "test_table"},
              record: %{"id" => "123", "name" => "Test"},
              log_offset: LogOffset.new(Lsn.from_integer(1000), 0)
            }
          ]
          |> changes_to_log_items()

        Storage.mark_snapshot_as_started(opts)
        Storage.make_new_snapshot!(@data_stream, opts)
        Storage.append_to_log!(log_items, opts)

        stream =
          Storage.get_log_stream(
            LogOffset.before_all(),
            LogOffset.last_before_real_offsets(),
            opts
          )

        assert Enum.count(stream) == Enum.count(@data_stream)
      end

      test "returns complete snapshot when the snapshot is concurrently being written", %{
        storage: opts
      } do
        row_count = 10

        data_stream =
          Stream.map(1..row_count, fn i ->
            # Sleep to give the read process time to run
            Process.sleep(1)

            [
              %{
                offset: @snapshot_offset_encoded,
                value: %{id: "00000000-0000-0000-0000-00000000000#{i}", title: "row#{i}"},
                key: ~S|"public"."the-table"/"00000000-0000-0000-0000-00000000000#{i}"|,
                headers: %{operation: "insert"}
              }
              |> Jason.encode_to_iodata!()
            ]
          end)

        Storage.mark_snapshot_as_started(opts)
        stream = Storage.get_log_stream(LogOffset.before_all(), LogOffset.first(), opts)

        read_task =
          Task.async(fn ->
            log = Enum.to_list(stream)

            assert Enum.count(log) == row_count

            for {item, i} <- Enum.with_index(log, 1) do
              assert Jason.decode!(item, keys: :atoms).value.title == "row#{i}"
            end
          end)

        Storage.make_new_snapshot!(data_stream, opts)

        Task.await(read_task)
      end
    end

    describe "#{module_name}.cleanup!/2" do
      setup do
        {:ok, %{module: unquote(module)}}
      end

      setup :start_storage

      test "causes snapshot_started?/2 to return false", %{module: storage, opts: opts} do
        storage.make_new_snapshot!(@data_stream, opts)

        storage.cleanup!(opts)

        assert storage.snapshot_started?(opts) == false
      end

      test "causes get_log_stream/4 to raise", %{module: storage, opts: opts} do
        lsn = Lsn.from_integer(1000)

        log_items =
          [
            %Changes.NewRecord{
              relation: {"public", "test_table"},
              record: %{"id" => "123", "name" => "Test"},
              log_offset: LogOffset.new(lsn, 0)
            }
          ]
          |> changes_to_log_items()

        storage.append_to_log!(log_items, opts)

        storage.cleanup!(opts)

        assert_raise Storage.Error, fn ->
          storage.get_log_stream(LogOffset.first(), LogOffset.last(), opts) |> Enum.to_list()
        end
      end
    end
  end

  # Tests for storage implementations that are recoverable
  for module <- [FileStorage] do
    module_name = module |> Module.split() |> List.last()

    describe "#{module_name}.compact/1" do
      setup do
        {:ok, %{module: unquote(module)}}
      end

      setup :start_storage

      test "can compact operations within a shape", %{storage: storage} do
        Storage.initialise(storage)
        Storage.mark_snapshot_as_started(storage)
        Storage.make_new_snapshot!([], storage)

        for i <- 1..10 do
          %Changes.UpdatedRecord{
            relation: {"public", "test_table"},
            old_record: %{"id" => "sameid", "name" => "Test#{i - 1}"},
            record: %{"id" => "sameid", "name" => "Test#{i}"},
            log_offset: LogOffset.new(i, 0),
            changed_columns: MapSet.new(["name"])
          }
        end
        # Super small chunk size so that each update is its own chunk
        |> changes_to_log_items(chunk_size: 5)
        |> Storage.append_to_log!(storage)

        assert Storage.get_log_stream(LogOffset.first(), LogOffset.new(7, 0), storage)
               |> Enum.to_list()
               |> length() == 7

        assert :ok = Storage.compact(storage)

        assert [line] =
                 Storage.get_log_stream(LogOffset.first(), LogOffset.new(7, 0), storage)
                 |> Enum.to_list()

        assert Jason.decode!(line, keys: :atoms) == %{
                 value: %{id: "sameid", name: "Test8"},
                 key: ~S|"public"."test_table"/"sameid"|,
                 headers: %{operation: "update", relation: ["public", "test_table"]}
               }
      end

      test "compaction doesn't bridge deletes", %{storage: storage} do
        Storage.initialise(storage)
        Storage.mark_snapshot_as_started(storage)
        Storage.make_new_snapshot!([], storage)

        for i <- 1..10 do
          update = %Changes.UpdatedRecord{
            relation: {"public", "test_table"},
            old_record: %{"id" => "sameid", "name" => "Test#{i - 1}"},
            record: %{"id" => "sameid", "name" => "Test#{i}"},
            log_offset: LogOffset.new(i, 0),
            changed_columns: MapSet.new(["name"])
          }

          if i == 5 do
            delete = %Changes.DeletedRecord{
              relation: {"public", "test_table"},
              old_record: %{"id" => "sameid", "name" => "Test#{i}"},
              log_offset: LogOffset.new(i, 1)
            }

            insert = %Changes.NewRecord{
              relation: {"public", "test_table"},
              record: %{"id" => "sameid", "name" => "Test#{i}"},
              log_offset: LogOffset.new(i, 2)
            }

            [update, delete, insert]
          else
            [update]
          end
        end
        |> List.flatten()
        # Super small chunk size so that each update is its own chunk
        |> changes_to_log_items(chunk_size: 5)
        |> Storage.append_to_log!(storage)

        assert Storage.get_log_stream(LogOffset.first(), LogOffset.new(7, 0), storage)
               |> Enum.to_list()
               |> length() == 9

        assert :ok = Storage.compact(storage)

        assert [op1, op2, op3, op4] =
                 Storage.get_log_stream(LogOffset.first(), LogOffset.new(7, 0), storage)
                 |> Enum.to_list()

        assert %{value: %{name: "Test5"}} = Jason.decode!(op1, keys: :atoms)
        assert %{headers: %{operation: "delete"}} = Jason.decode!(op2, keys: :atoms)
        assert %{headers: %{operation: "insert"}} = Jason.decode!(op3, keys: :atoms)

        assert %{headers: %{operation: "update"}, value: %{name: "Test8"}} =
                 Jason.decode!(op4, keys: :atoms)
      end

      test "compaction works multiple times", %{storage: storage} do
        Storage.initialise(storage)
        Storage.mark_snapshot_as_started(storage)
        Storage.make_new_snapshot!([], storage)

        for i <- 1..10 do
          %Changes.UpdatedRecord{
            relation: {"public", "test_table"},
            old_record: %{"id" => "sameid", "name" => "Test#{i - 1}"},
            record: %{"id" => "sameid", "name" => "Test#{i}"},
            log_offset: LogOffset.new(i, 0),
            changed_columns: MapSet.new(["name"])
          }
        end
        # Super small chunk size so that each update is its own chunk
        |> changes_to_log_items(chunk_size: 5)
        |> Storage.append_to_log!(storage)

        assert Storage.get_log_stream(LogOffset.first(), LogOffset.new(7, 0), storage)
               |> Enum.to_list()
               |> length() == 7

        # Force compaction of all the lines
        assert :ok = Storage.compact(storage, LogOffset.new(10, 0))

        assert Storage.get_log_stream(LogOffset.first(), LogOffset.new(10, 0), storage)
               |> Enum.to_list()
               |> length() == 1

        for i <- 10..20 do
          %Changes.UpdatedRecord{
            relation: {"public", "test_table"},
            old_record: %{"id" => "sameid", "other_name" => "Test#{i - 1}"},
            record: %{"id" => "sameid", "other_name" => "Test#{i}"},
            log_offset: LogOffset.new(i, 0),
            # Change the other column here to make sure previous are also included in the compaction
            changed_columns: MapSet.new(["other_name"])
          }
        end
        # Super small chunk size so that each update is its own chunk
        |> changes_to_log_items(chunk_size: 5)
        |> Storage.append_to_log!(storage)

        assert :ok = Storage.compact(storage)

        assert [line] =
                 Storage.get_log_stream(LogOffset.first(), LogOffset.new(17, 0), storage)
                 |> Enum.to_list()

        assert Jason.decode!(line, keys: :atoms) == %{
                 value: %{id: "sameid", name: "Test10", other_name: "Test18"},
                 key: ~S|"public"."test_table"/"sameid"|,
                 headers: %{operation: "update", relation: ["public", "test_table"]}
               }
      end
    end

    describe "#{module_name}.initialise/1" do
      setup do
        {:ok, %{module: unquote(module)}}
      end

      setup :start_storage

      test "removes the shape if the shape definition has not been set", %{
        module: storage,
        opts: opts
      } do
        storage.initialise(opts)

        # storage.set_shape_definition(@shape, opts)
        storage.mark_snapshot_as_started(opts)
        storage.make_new_snapshot!(@data_stream, opts)
        storage.set_pg_snapshot(%{xmin: 11, xmax: 12, xip_list: []}, opts)
        assert storage.snapshot_started?(opts)

        storage.initialise(opts)

        refute storage.snapshot_started?(opts)
      end

      test "removes the shape if pg_snapshot has not been set", %{
        module: storage,
        opts: opts
      } do
        storage.initialise(opts)

        storage.set_shape_definition(@shape, opts)
        storage.mark_snapshot_as_started(opts)
        storage.make_new_snapshot!(@data_stream, opts)
        assert storage.snapshot_started?(opts)

        storage.initialise(opts)

        refute storage.snapshot_started?(opts)
      end

      test "removes the shape if the snapshot has not finished", %{
        module: storage,
        opts: opts
      } do
        storage.initialise(opts)

        storage.set_shape_definition(@shape, opts)
        storage.mark_snapshot_as_started(opts)
        storage.set_pg_snapshot(%{xmin: 22, xmax: 23, xip_list: []}, opts)

        storage.initialise(opts)

        refute storage.snapshot_started?(opts)
      end

      test "removes all shapes if the storage version has changed", %{
        module: storage,
        opts: opts
      } do
        storage.initialise(opts)

        storage.set_shape_definition(@shape, opts)
        storage.mark_snapshot_as_started(opts)
        storage.make_new_snapshot!(@data_stream, opts)
        storage.set_pg_snapshot(%{xmin: 11, xmax: 12, xip_list: []}, opts)

        storage.initialise(%{opts | version: "new-version"})

        refute storage.snapshot_started?(opts)
      end
    end

    describe "#{module_name}.get_all_stored_shapes/1" do
      setup do
        {:ok, %{module: unquote(module)}}
      end

      setup :start_storage

      test "retrieves no shapes if no shapes persisted", %{
        module: storage,
        opts: opts
      } do
        assert {:ok, %{}} = Electric.ShapeCache.Storage.get_all_stored_shapes({storage, opts})
      end

      test "retrieves stored shapes", %{
        module: storage,
        opts: opts
      } do
        storage.initialise(opts)
        storage.set_shape_definition(@shape, opts)

        assert {:ok, %{@shape_handle => parsed}} =
                 Electric.ShapeCache.Storage.get_all_stored_shapes({storage, opts})

        assert @shape == parsed
      end
    end

    describe "#{module_name}.unsafe_cleanup/1" do
      setup do
        {:ok, %{module: unquote(module)}}
      end

      setup :start_storage

      test "should remove entire data directory without requiring process to run", %{
        module: storage,
        opts: opts,
        pid: pid
      } do
        lsn = Lsn.from_integer(1000)

        log_items =
          [
            %Changes.NewRecord{
              relation: {"public", "test_table"},
              record: %{"id" => "123", "name" => "Test"},
              log_offset: LogOffset.new(lsn, 0)
            }
          ]
          |> changes_to_log_items()

        storage.append_to_log!(log_items, opts)

        Process.exit(pid, :normal)

        assert File.exists?(opts.data_dir)

        storage.unsafe_cleanup!(opts)

        refute File.exists?(opts.data_dir)
      end
    end

    describe "#{module_name}.get_total_disk_usage/1" do
      setup do
        {:ok, %{module: unquote(module)}}
      end

      test "returns 0 if no shapes exist", %{module: module} = context do
        opts = module |> opts(context) |> module.shared_opts()

        assert 0 = Electric.ShapeCache.Storage.get_total_disk_usage({module, opts})
      end

      test "returns the total disk usage for all shapes", %{module: storage} = context do
        {:ok, %{opts: shape_opts, shared_opts: opts}} = start_storage(context)

        storage.initialise(shape_opts)
        storage.set_shape_definition(@shape, shape_opts)

        assert Electric.ShapeCache.Storage.get_total_disk_usage({storage, opts}) > 2300
      end

      test "returns the total disk usage with FS failures", %{module: storage} = context do
        {:ok, %{opts: shape_opts, shared_opts: opts}} = start_storage(context)
        storage.initialise(shape_opts)
        storage.set_shape_definition(@shape, shape_opts)

        Repatch.patch(File, :ls, fn _ -> {:error, :enoent} end)
        assert 0 = Electric.ShapeCache.Storage.get_total_disk_usage({storage, opts})

        Repatch.cleanup()
        Repatch.patch(File, :stat, fn _ -> {:error, :enoent} end)
        assert 0 = Electric.ShapeCache.Storage.get_total_disk_usage({storage, opts})
      end
    end
  end

  defp start_storage(%{module: module} = context) do
    opts = module |> opts(context) |> module.shared_opts()
    shape_opts = module.for_shape(@shape_handle, opts)
    pid = start_link_supervised!({module, shape_opts})
    {:ok, %{opts: shape_opts, shared_opts: opts, pid: pid, storage: {module, shape_opts}}}
  end

  defp start_empty_snapshot(%{storage: storage}) do
    Storage.mark_snapshot_as_started(storage)
    Storage.make_new_snapshot!([], storage)

    :ok
  end

  defp opts(InMemoryStorage, %{stack_id: stack_id}) do
    [
      snapshot_ets_table: String.to_atom("snapshot_ets_table_#{Utils.uuid4()}"),
      log_ets_table: String.to_atom("log_ets_table_#{Utils.uuid4()}"),
      chunk_checkpoint_ets_table: String.to_atom("chunk_checkpoint_ets_table_#{Utils.uuid4()}"),
      stack_id: stack_id
    ]
  end

  defp opts(FileStorage, %{tmp_dir: tmp_dir, stack_id: stack_id}) do
    [
      db: String.to_atom("shape_mixed_disk_#{Utils.uuid4()}"),
      storage_dir: tmp_dir,
      stack_id: stack_id
    ]
  end
end
