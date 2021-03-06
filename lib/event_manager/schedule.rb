require 'active_support/core_ext/time/calculations'
=begin rdoc

This handles all of the logic right now.

Encoding is heavely based off of ICS format
http://www.ietf.org/rfc/rfc2445.txt
4.3.10 Recurrence Rule
It is HIGHLY suggested to read through the entire section before reading this code. By sticking closely to the ICS format, we should be able to easily expand out the options if we want to handle more cases.

== Attributes

[freq]          identifies type of recurrance. i.e. :daily, :weekly, :monthly (required)
[interval]      how often to repeat (positive value, default = 1). Interval of 2 would be "every other [freq]"
[by_day]        list of days, with possible value in front. (see ics BYDAY).
                  i.e. [MO,TU] would be Monday and Tuesday. [1MO,2TU] would be first monday (of the month)
                  and 2nd Tuesday (of the month).
[by_month_day]  integer representing day in month, postive or negative.
                  i.e. [4] would be the 4th of the month. [-2,-4] would be the 2nd to last day and 4th to last day.
[wkst]          defines when the week starts (defaults to Monday) - can't currently change
[duration]      breaking from ics a little here - ics assumes start/end dates to figure out how long
                  an event should be and how to repeat it. I'm changing it a little by having a
                  duration in _days_. My approach is for the schedule to define when something is
                  DUE, and then duration should be how many days the event is.
[event_start]    when this schedule should go into effect.

=end

module EventManager
  module Schedule

    attr_accessor :freq
    attr_accessor :interval
    attr_accessor :by_day
    attr_accessor :by_month_day
    attr_accessor :wkst
    attr_accessor :duration

    attr_accessor :event_start

    ##
    # set the default values
    def initialize
      @interval = 1
      @wkst = :mo
      @id = rand(100)
      @duration = 0 # 1 day
      @event_start = DateTime.new
    end

    # The list of frequencies currently supported
    FREQ = [:weekly, :monthly]

    # List of days of week
    DAYS = [:su, :mo, :tu, :we, :th, :fr, :sa]

    ##
    # Finds the next occurance of the schedule as long as it is between the two dates.
    #
    # This is invisioned to be a public method.
    #
    # == Attributes
    #
    # [+after_date+]  Date which to search after.
    #
    # == Return
    #
    # Returns a date of when the next event happens after the search date.
    def next_event_after(after_date, start = event_start)
      first_occurrence = next_occurrence(start,true)

      if after_date < first_occurrence
        first_occurrence
      elsif n = next_occurrence(after_date)
        n
        # I don't like having this type of conditional here, but
        # `first_group` and `next_group` don't make sense for :monthly
      elsif @freq == :monthly
        next_occurrence(after_date,true)
      else
        # Find the first group for this event happened
        first_group = first_group(first_occurrence)
        next_event_after(next_group(first_group, after_date))
      end
    end

    ##
    # Get a list of events that happen between two dates.
    #
    # == Attributes
    #
    # [+date_start+]  Date on which you want the search to start.
    # [+date_end+]    Date when you want the search to stop.
    #
    # == Return
    #
    # Returns an array of +Event+ structs each having +event_start+
    # and +end_date+. These events will happen on or after the +date_start+
    # and before +date_end+.
    def events_between(date_start, date_end, start = event_start)

      events = []
      current_date = date_start

      while current_date <= date_end
        current_date = next_event_after(current_date, start)
        if current_date <= date_end
          event = {start_date: current_date, end_date: current_date + duration}
          yield(event) if block_given?
          events << event
        end
        # add one day so it doesn't return the same day
        # probably shouldn't need to do this
        current_date += 1
      end

      events
    end

    # At some point everything below this should be private
    # private


    ##
    # Encodes the days_of_week so that it can be saved to database.
    #
    # == Attributes
    #
    # [+days_of_week+]  This is an array of strings with two letter representaiton of the day.
    #                     i.e. ["Mo", "We", "Fr"]
    # [+offset+]        String with the number of offset. According to ICS each day could have
    #                     it's own offset, but for now, every day will get the same one.
    #                     i.e. '2'
    #
    # == Return
    #
    # Returns a string format of the array.
    #   i.e. '2mo,2we'
    def encode_by_day(days_of_week, offset = '')
      selected_days = days_of_week.map do |day|
        d = day.downcase.to_sym
        DAYS.include?(d) ? (offset + d.to_s) : nil
      end
      selected_days.compact.join(",")
    end

    def encode_by_month_day(days_of_month)
      selected_days = days_of_month.map do |day|
        day.to_i != 0 ? day : nil
      end
      selected_days.compact.join(",")
    end

    ##
    # Used for "first Monday of the month" or "last Monday of the month"
    #
    # Offset has to be > 0
    #
    # == Attributes
    #
    # [year]    Year in which to find the valid date
    # [month]   Month in which to find the valid date
    # [offset]  What offset to find. i.e 2 would be "second [wday] of month"
    # [wday]    Which day of the week to find.
    #
    # == Return
    #
    # Returns a day that satisfies the offset and wday.
    def day_of_month(year,month,offset,wday, tz_offset = event_start.offset)
      first = DateTime.new(year,month,1,0,0,0, tz_offset) # first day of month
      last = DateTime.new(year,month,1,0,0,0, tz_offset).next_month - 1 # grab the last day
      if offset > 0
        # offset to get to the right wday
        wday_offset = wday - first.wday
        # if the start of the week is actually greater, then add 7 to to first instance
        wday_offset += 7 if wday_offset < 0
        # which instance are we looking for?
        week_offset = 7 * (offset-1)
        answer = first + wday_offset + week_offset
        # [last, answer].min
        if answer.month == month
          answer
        else
          day_of_month(year,month,-1,wday, tz_offset)
        end
      else
        # offset to get to the right wday
        wday_offset = wday - last.wday
        # if the offset is positive, we want to make it negative
        wday_offset -= 7 if wday_offset > 0
        # which instance are we looking for?
        week_offset = 7 * (offset+1)
        answer = last + wday_offset + week_offset
        # [first, answer].max
        if answer.month == month
          answer
        else
          day_of_month(year,month,1,wday, tz_offset)
        end
      end
    end

    ##
    # Take params from a form and build the needed attributes
    #
    # == Attributes
    #
    # See list of attributes above
    def create(params)

      if (params[:freq] && FREQ.include?(params[:freq].to_sym))
        @freq = params[:freq].to_sym
      end

      @interval = params[:interval].to_i if params[:interval]

      if params[:days_of_week] && params[:days_of_week_offset]
        @by_day = encode_by_day(params[:days_of_week], params[:days_of_week_offset])
      elsif params[:days_of_week]
        @by_day = encode_by_day(params[:days_of_week])
      end

      if params[:days_of_month]
        @by_month_day = encode_by_month_day(params[:days_of_month])
      end

      @duration = params[:duration].to_i if params[:duration]
      @event_start = params[:event_start]
    end

    ##
    # Check to see if the schedule is valid
    #
    # Right now this is a pretty simple validation. Just
    # need to make sure the +@freq+ is set and that the
    # +@duration+ is longer than the frequency_length
    def valid?
      if @freq.nil?
        false
      elsif frequency_length < @duration
        false
      else
        true
      end
    end

    ##
    # This is just used for the validation method.
    #
    # This is a pretty simplistic view. Might not be robust
    # enough going forward. Especially monthly.
    def frequency_length
      if @freq == :daily
        @interval * 1
      elsif @freq == :weekly
        @interval * 7
      elsif @frequency == :monthly
        @interval * 29 # technically this is short, but I think it is fine for now
      end
    end

    ##
    # This decodes +@by_day+ into a nested array.
    #
    # == Return
    #
    # It returns a nested array. The outside array is for each day.
    # The inside array always has two elements. The first is the offset,
    # the second is the day of the week number (wday).
    # An example would be the "second Monday of the month" which would
    # look like: [2,1]
    #
    # Examples:
    # 'mo' => [[1,1]]
    # 'mo,we,fr' => [[1,1],[1,3],[1,5]]
    def decode_by_day
      days = @by_day.split(',')
      days.map do |day|
        if day.length == 2
          [ 1, DAYS.index(day.to_sym)]
        elsif day.length == 3
          [ day[0].to_i, DAYS.index(day[1..-1].to_sym) ]
        else
          [ day[0..-3].to_i, DAYS.index(day[-2..-1].to_sym) ]
        end
      end
    end

    ##
    # Used for the +:weekly+ and +:monthly+ frequencies. This
    # takes the output of +decode_by_day+, sorts it, and then
    # returns the index of the first day in the group.
    #
    # This normally shouldn't _need_ to do anything. They should
    # be in order, but that can't be gurenteed coming from the form.
    # Maybe instead this should be sorted before saving to the db.
    #
    # == Return
    #
    # Returns the index of the first day in +decode_by_day+
    def first_day
      if @freq == :weekly || (@freq == :monthly && @by_day)
        days = decode_by_day
        first_day = days.sort {|x,y| x[1] <=> y[1] }.first
        days.index(first_day)
      end
    end

    ##
    # Used to find the next time an event should happen aften a given date.
    #
    # This does not take into account the interval.
    #
    # This is the most complicated method since it does deal with the logic
    # for each kind of frequency.
    #
    # == Attributes
    #
    # [+event_start+]  What date to search after.
    # [+continue+]    This option is if it should look into the following
    #                   freq or not (i.ee look at the next week).
    #
    # == Return
    #
    # It will return the date of the next time an event will happen within
    # the frequency. If it doesn't find one it will return +nil+, unless
    # +continue+ is true, in which case it will go to the next frequency.
    def next_occurrence(start, continue=false)
      if @freq == :weekly
        wday = start.wday
        days = decode_by_day # i.e. [[1,1]] -
        # we want the first occurance where wday <= given day
        # example: schedule is [:mo,:we,:fr]
        # days = [[1,1],[1,3],[1,5]]
        # if our start is Sunday (wday=0), we want to stop on Monday (0 <= 1)
        # if our start is Tuesday (wday=2), we want to stop on Wednesday ( 2 <= 3)
        # if our start is Saturday (wday=6), we want the following Monday
        day_index = days.index { |day| wday <= day[1] }
        # if it is nil, we want the earliest day of the week
        if continue && day_index.nil?
          # I'd like to assume they are in order, but is that guaranteed?
          day_index = first_day
          # We then need to bump up the start a week
          start+=7
        elsif day_index.nil?
          return nil
        end
        # day will be the wday of the first matching date
        day = days[day_index][1]
        # we want to return the start plus the number of days till the firt match
        start + (day - wday)
      elsif @freq == :monthly && @by_day
        # Given the start we can grab month/year
        # go through each of the days and
        # return if it is greater than start
        # else ask if it needs to go to the following month (recursion)
        days = decode_by_day
        days.each do |d|
          day_in_month = day_of_month(start.year,start.month,*d, start.offset) # star to break array into two attributes
          return day_in_month if day_in_month >= start
        end
        # if it didn't find a match, then ask if it needs to continue
        if continue
          # Call the next month
          next_month = DateTime.new(start.year,start.month+1,1,0,0,0, start.offset)
          self.next_occurrence(next_month, continue)
        else
          nil
        end
      elsif @freq == :monthly && @by_month_day
        # Given start we know the day of month and we loop around
        # by_month_day until we find one bigger (unless negative). If not, retun nil unless continue = true,
        # in which case, grab the first one from by_month, and get it from the next month
        start_days_in_month = Time.days_in_month(start.month, start.year)
        neg_start = start.mday - start_days_in_month
        month_days = @by_month_day.split(',').map(&:to_i).sort
        day_index = month_days.index do |mday|
          if mday < 0
            # handle negatives
            neg_start <= mday
          else
            start.mday <= mday
          end
        end
        if !day_index.nil? && month_days[day_index] <= start_days_in_month
          day = month_days[day_index]
          DateTime.new(start.year, start.month, day,0,0,0, start.offset)
        elsif continue
          DateTime.new(start.year, start.month+1, month_days.first,0,0,0, start.offset)
        else
          nil
        end
      end
    end

    ##
    # Returns the first day for the frequency. Might not be the first occurrence.
    #
    # TODO: Looks like this is only being used for +:weekly+. I think this
    # ended up with the multiple +elseif+ within +next_occurrence+ due to
    # edge cases. Totally up for restructuring the logic for these methods.
    #
    # TODO: looks like there might be an edge case that isn't being handled.
    # This could return a date that is _before_ your +event_start+. That is if
    # it is MWF and you give it Saturday, it will give you Monday of that week.
    # Therefore when you use this method, you should have to check to see
    # if it is infact greater than +event_start+, if not, then find the next
    # occurance of it. I think.
    #
    # == Attributes
    #
    # [event_start]  Date within frequency which to find the first occurrance.
    #
    # == Return
    #
    # Returns a date which is the correct weekday (wday) next to +event_start+.
    def first_group(event_start)
      if @freq == :weekly
        # Grab the first wday within the schedule
        wday = decode_by_day[first_day][1]
        # Based off the start date add the number of days it takes to get to
        # the correct week day.
        # i.e. event_start is Friday (5) and wday is Monday(1)
        # event_start + (1 - 5) = Friday - 4 = Monday of that week.
        event_start + (wday - event_start.wday)
        # elsif @freq == :monthly
        #   day = decode_by_day[first_day]
        #   day_of_month(event_start.year,event_start.month,*day)
      end
    end

    ##
    # Returns the first date, for a grouping of events
    #
    # == Attributes
    #
    # [+first_occurrence+]  The first time this schedule _does_ happen.
    # [+after_date+]        The date which you want the group to happen _after_.
    #
    # == Return
    #
    # Date of the first day in the group that happens after the search date.
    #
    # i.e. if a schedule is MWF, then it will return the Monday
    # if it is every other week then it will return the following Monday that matches
    def next_group(first_occurrence,after_date)
      # Offset to add to the first_occurrence
      period = 0

      # period = days between repeated events
      if @freq == :weekly
        period = 7.0 * self.interval
      else
        nil
      end

      # diff = days between our `after_date` and the `first_occurrence`
      diff = after_date - first_occurrence
      # diff = 0 if diff < 0
      # ( diff / period ) - we want to find how many `period`s happened during that `diff`
      # _.ceil - we want to round up so that we usually get at least one period
      # _ * period - multiply by that period to get the right offset
      # _ = days on or after which our next occurance is
      days_after = ( diff / period ).ceil * period
      # puts "days_after = ( #{diff} / #{period} ).ceil * #{period} = #{days_after}"
      first_occurrence + days_after
    end


  end

  def self.included(base)
    base.send :include, Schedule
  end

end
