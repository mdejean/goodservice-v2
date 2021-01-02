class RouteProcessor
  RUNTIME_END_LIMIT = 30.minutes
  RUNTIME_START_LIMIT = 40.minutes

  def self.process_route(route_id, trips, timestamp)
    trips_by_direction = trips.group_by(&:direction)

    routings = determine_routings(trips_by_direction)

    trips_by_routes = trips_by_direction.map { |direction, trips|
      [direction, routings[direction].map {|r|
        [r, trips.sort_by { |t| t.stops.size }.reverse.select { |t|
          stops = t.stop_ids
          r.each_cons(stops.length).any?(&stops.method(:==))
        }]
      }.to_h]
    }.to_h

    headway_by_routes = trips_by_routes.map { |direction, routes|
      [direction, routes.map { |r, trips|
        [r, trips.each_cons(2).map{ |a_trip, b_trip|
          time_between_trips(a_trip, b_trip, timestamp, r)
        }.max]
      }.to_h]
    }.to_h

    puts "Headway by Routes for #{route_id} - N: #{headway_by_routes[1]}"
    puts "Headway by Routes for #{route_id} - S: #{headway_by_routes[3]}"

    REDIS_CLIENT.set("last-update:#{route_id}", timestamp, ex: 3600)
  end

  def self.determine_routings(trips_by_direction)
    trips_by_direction.map { |direction, t|
      [direction, determine_routings_for_direction(t)]
    }.to_h
  end

  def self.determine_routings_for_direction(trips)
    trips.map(&:stop_ids).sort_by(&:size).reverse.inject([]) do |memo, stops_array|
      unless memo.any? { |array| (stops_array - array).empty? }
        memo << stops_array
      end
      memo
    end
  end

  def self.time_between_trips(a_trip, b_trip, timestamp, routing)

    (time_until_upcoming_stop(a_trip, timestamp, routing) +
      a_trip.stops_behind(b_trip).each_cons(2).map { |a_stop, b_stop| average_travel_time(a_stop, b_stop, timestamp) }.sum -
      time_until_upcoming_stop(b_trip, timestamp, routing)) / 60
  end

  def self.time_until_upcoming_stop(trip, timestamp, routing)
    next_stop = trip.upcoming_stop
    i = routing.index(next_stop)
    return trip.time_until_upcoming_stop if i == 0

    previous_stop = routing[i - 1]
    predicted_time_until_next_stop = trip.time_until_upcoming_stop
    predicted_time_between_stops = REDIS_CLIENT.hget("travel-time:supplementary", "#{previous_stop}-#{next_stop}").to_f
    actual_time_between_stops = average_travel_time(previous_stop, next_stop, timestamp)

    (predicted_time_until_next_stop / predicted_time_between_stops) * actual_time_between_stops
  end

  def self.average_travel_time(a_stop, b_stop, timestamp)
    train_stops_at_b = REDIS_CLIENT.zrevrangebyscore("stops:#{b_stop}", timestamp + 1.minute.to_i, timestamp - RUNTIME_END_LIMIT.to_i, withscores: true).to_h
    train_stops_at_a = REDIS_CLIENT.zrangebyscore("stops:#{a_stop}", timestamp - RUNTIME_START_LIMIT.to_i, timestamp + 1.minute.to_i, withscores: true).to_h

    trains_stopped_at_a = train_stops_at_a.map(&:first)
    trains_traveled = train_stops_at_b.select{ |b_train, _| train_stops_at_a.find {|a_train, _| a_train == b_train } }.keys

    return REDIS_CLIENT.hset("travel-time:supplementary", "#{a_stop}-#{b_stop}", timestamp) unless trains_traveled.present?

    trains_traveled.map { |train_id| train_stops_at_b[train_id] - train_stops_at_a[train_id] }.sum / trains_traveled.size
  end
end