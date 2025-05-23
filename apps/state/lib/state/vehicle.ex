defmodule State.Vehicle do
  @moduledoc """
  Maintains the list of currently active vehicles.  Queryable by:
  * vehicle ID
  * trip ID
  * route ID
  * label
  """
  use State.Server,
    indices: [:id, :trip_id, :effective_route_id],
    parser: Parse.VehiclePositions,
    recordable: Model.Vehicle,
    hibernate: false

  alias Model.Vehicle
  alias State.Trip

  @type filter_opts :: %{
          optional(:labels) => [String.t(), ...],
          optional(:routes) => [Model.Route.id(), ...],
          optional(:direction_id) => Model.Direction.id() | nil,
          optional(:route_types) => [Model.Route.route_type(), ...],
          optional(:revenue) => [:NON_REVENUE | :REVENUE]
        }

  @impl State.Server
  def post_load_hook(structs) do
    Enum.uniq_by(structs, & &1.trip_id)
  end

  @spec by_id(Vehicle.id()) :: Vehicle.t() | nil
  def by_id(id) do
    case super(id) do
      [] -> nil
      [vehicle] -> vehicle
    end
  end

  @impl State.Server
  def pre_insert_hook(vehicle) do
    if has_invalid_dir(vehicle) do
      Logger.warning("Found vehicle with invalid direction: #{inspect(vehicle)}")
    end

    update_effective_route_id(vehicle)
  end

  @spec has_invalid_dir(Vehicle.t()) :: boolean()
  defp has_invalid_dir(vehicle) do
    not_shuttle = vehicle.route_id != nil and not String.starts_with?(vehicle.route_id, "Shuttle")

    invalid_dir = vehicle.direction_id not in [0, 1]

    not_shuttle and invalid_dir
  end

  defp update_effective_route_id(%Vehicle{trip_id: trip_id} = vehicle) do
    case Trip.by_id(trip_id) do
      [] ->
        # make sure the effective_route_id is assigned since that's what we
        # query for
        [%{vehicle | effective_route_id: vehicle.route_id}]

      trips ->
        for trip <- trips do
          %{vehicle | effective_route_id: trip.route_id}
        end
    end
  end

  @spec filter_by(filter_opts) :: [Vehicle.t()]
  def filter_by(%{} = filters) do
    idx = get_index(filters)

    [%{}]
    |> build_filters(:effective_route_id, Map.get(filters, :routes), filters)
    |> build_filters(:route_type, Map.get(filters, :route_types), filters)
    |> build_filters(:revenue, Map.get(filters, :revenue, [:REVENUE]), filters)
    |> State.Vehicle.select(idx)
    |> do_post_search_filter(filters)
  end

  defp get_index(%{routes: routes}) when routes != [], do: :effective_route_id
  defp get_index(_filters), do: nil

  defp build_filters(matchers, _key, nil, _filters), do: matchers

  defp build_filters(matchers, :route_type, route_types, _filters) do
    route_ids =
      route_types
      |> State.Route.by_types()
      |> Enum.map(& &1.id)

    valid_route_id? = fn matcher, route_id ->
      case matcher do
        %{effective_route_id: ^route_id} -> true
        %{effective_route_id: _} -> false
        _ -> true
      end
    end

    for matcher <- matchers, route_id <- route_ids, valid_route_id?.(matcher, route_id) do
      Map.put(matcher, :effective_route_id, route_id)
    end
  end

  defp build_filters(matchers, :effective_route_id, route_ids, filters) do
    direction_id = filters[:direction_id] || :_

    for matcher <- matchers, route_id <- route_ids do
      matcher
      |> Map.put(:effective_route_id, route_id)
      |> Map.put(:direction_id, direction_id)
    end
  end

  defp build_filters(matchers, key, values, _filters) do
    for matcher <- matchers, value <- List.wrap(values), do: Map.put(matcher, key, value)
  end

  @spec do_post_search_filter([Vehicle.t()], filter_opts) :: [Vehicle.t()]
  defp do_post_search_filter(vehicles, %{labels: labels}) when is_list(labels) do
    labels = MapSet.new(labels)

    consist_matches? = fn %Model.Vehicle{consist: consist} ->
      case consist do
        nil ->
          false

        _ ->
          not MapSet.disjoint?(labels, MapSet.new(consist))
      end
    end

    label_matches? = fn %Model.Vehicle{label: label} ->
      label in labels
    end

    Enum.filter(vehicles, fn vehicle ->
      label_matches?.(vehicle) or consist_matches?.(vehicle)
    end)
  end

  defp do_post_search_filter(vehicles, _filters), do: vehicles
end
