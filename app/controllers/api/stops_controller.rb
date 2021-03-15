class Api::StopsController < ApplicationController
  def index
    data = Rails.cache.fetch("stops", expires_in: 10.seconds) do
      stops = Scheduled::Stop.all
      futures = {}
      REDIS_CLIENT.pipelined do
        futures = stops.to_h { |stop|
          [stop.internal_id, [1, 3].to_h { |direction|
            [direction, RedisStore.routes_stop_at(stop.internal_id, direction, Time.current.to_i)]
          }]
        }
      end
      {
        stops: Naturally.sort_by(stops){ |s| "#{s.stop_name}#{s.secondary_name}" }.map { |s|
          route_directions = transform_to_route_directions_hash(futures[s.internal_id])
          {
            id: s.internal_id,
            name: s.stop_name,
            secondary_name: s.secondary_name,
            routes: route_directions,
            transfers: transfers[s.internal_id]&.map{ |t| t.to_stop_internal_id }
          }
        },
        timestamp: Time.current.to_i,
      }
    end

    expires_now
    render json: data
  end

  def show
    stop_id = params[:id]
    data = Rails.cache.fetch("stops:#{stop_id}", expires_in: 10.seconds) do
      timestamp = Time.current.to_i
      stop = Scheduled::Stop.find_by!(internal_id: stop_id)
      route_stops_futures = {}
      status_future = nil
      REDIS_CLIENT.pipelined do
        route_stops_futures = [1, 3].to_h { |direction|
          [direction, RedisStore.routes_stop_at(stop.internal_id, direction, Time.current.to_i)]
        }
        status_future = RedisStore.route_status_summaries
      end
      route_directions = transform_to_route_directions_hash(route_stops_futures)
      route_ids = route_directions.keys
      statuses = status_future.value

      routes = Scheduled::Route.where(internal_id: route_ids).to_h do |route|
        status = "No Service"
        route_data_encoded = statuses[route.internal_id]
        route_data = route_data_encoded ? JSON.parse(route_data_encoded) : {}
        if route_data['timestamp'] >= (Time.current - 5.minutes).to_i
          status = route_data['status']
        end

        [route.internal_id, {
          id: route.internal_id,
          name: route.name,
          color: route.color && "##{route.color}",
          text_color: route.text_color && "##{route.text_color}",
          alternate_name: route.alternate_name,
          status: status,
          directions: route_directions[route.internal_id]
        }]
      end

      route_futures = {}
      REDIS_CLIENT.pipelined do
        route_futures = route_ids.to_h do |route_id|
          [route_id, RedisStore.processed_trips(route_id)]
         end
      end
      trips_by_routes_array = route_ids.map do |route_id|
        marshaled_trips = route_futures[route_id].value
        next unless marshaled_trips
        Marshal.load(marshaled_trips)
      end
      routings = trips_by_routes_array.flat_map do |route_hash|
        route_hash.values.flat_map do |trips_by_routes|
          trips_by_routes.values.map do |trips|
            upcoming_stops = trips.first.upcoming_stops
            i = upcoming_stops.index(stop_id)
            upcoming_stops[0..i]
          end
        end
      end
      travel_times = routings.map { |r|
        RouteProcessor.batch_average_travel_times(r, timestamp)
      }.reduce({}, :merge)

      trips = [1, 3].to_h { |direction|
        [direction, trips_by_routes_array.flat_map { |route_hash|
            route_hash[direction]&.values&.flatten&.uniq { |t| t.id }
          }.select { |trip|
            trip&.upcoming_stops(time_ref: timestamp)&.include?(stop_id)
          }.sort_by { |trip| trip.stops[stop_id]}.map { |trip| transform_trip(stop_id, trip, travel_times, timestamp) }
        ]
      }
      {
        id: stop.internal_id,
        name: stop.stop_name,
        secondary_name: stop.secondary_name,
        upcoming_trips: RouteAnalyzer.convert_to_readable_directions(trips),
        timestamp: Time.current.to_i,
      }
    end

    expires_now
    render json: data
  end

  private

  def transform_to_route_directions_hash(direction_futures_hash)
    routes_by_direction = direction_futures_hash.to_h do |direction, future|
      [direction, future.value]
    end
    routes = routes_by_direction.values.flatten.uniq.sort
    routes.to_h do |route_id|
      directions_array = []
      if routes_by_direction[1].include?(route_id)
        directions_array << "north"
      end
      if routes_by_direction[3].include?(route_id)
        directions_array << "south"
      end
      [route_id, directions_array]
    end
  end

  def transform_trip(stop_id, trip, travel_times, timestamp)
    upcoming_stops = trip.upcoming_stops
    i = upcoming_stops.index(stop_id)
    estimated_current_stop_arrival_time = trip.estimated_upcoming_stop_arrival_time
    if i > 0
      estimated_current_stop_arrival_time += upcoming_stops[0..i].each_cons(2).map { |a_stop, b_stop|
        travel_times["#{a_stop}-#{b_stop}"] || RedisStore.supplemented_scheduled_travel_time(a_stop, b_stop) || RedisStore.scheduled_travel_time(a_stop, b_stop) || 0
      }.reduce(&:+)
    end
    {
      id: trip.id,
      route_id: trip.route_id,
      previous_stop: trip.previous_stop,
      previous_stop_arrival_time: trip.previous_stop_arrival_time,
      upcoming_stop: trip.upcoming_stop,
      upcoming_stop_arrival_time: trip.upcoming_stop_arrival_time,
      estimated_upcoming_stop_arrival_time: trip.estimated_upcoming_stop_arrival_time,
      current_stop_arrival_time: trip.stops[stop_id],
      estimated_current_stop_arrival_time: estimated_current_stop_arrival_time,
      destination_stop: trip.destination,
      delayed_time: trip.delayed_time,
      schedule_discrepancy: trip.schedule_discrepancy,
      is_delayed: trip.delayed?,
      timestamp: trip.timestamp,
    }
  end

  def transfers
    @transfers ||= Scheduled::Transfer.where("from_stop_internal_id <> to_stop_internal_id").group_by(&:from_stop_internal_id)
  end
end