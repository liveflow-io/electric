defmodule Electric.Replication.Supervisor do
  use Supervisor

  require Logger

  def name(opts) do
    Electric.ProcessRegistry.name(opts[:stack_id], __MODULE__)
  end

  def start_link(opts) do
    name = Access.get(opts, :name, name(opts))
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    Process.set_label({:replication_supervisor, opts[:stack_id]})
    Logger.metadata(stack_id: opts[:stack_id])
    Electric.Telemetry.Sentry.set_tags_context(stack_id: opts[:stack_id])
    Logger.info("Starting shape replication pipeline")

    # TODO: weird to have these without defaults but `consumer_supervisor` with a default
    shape_cache = Keyword.fetch!(opts, :shape_cache)
    publication_manager = Keyword.fetch!(opts, :publication_manager)
    log_collector = Keyword.fetch!(opts, :log_collector)
    schema_reconciler = Keyword.fetch!(opts, :schema_reconciler)
    stack_id = Keyword.fetch!(opts, :stack_id)

    consumer_supervisor =
      Keyword.get(
        opts,
        :consumer_supervisor,
        {Electric.Shapes.DynamicConsumerSupervisor, [stack_id: stack_id]}
      )

    children = [
      consumer_supervisor,
      publication_manager,
      log_collector,
      shape_cache,
      schema_reconciler
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
