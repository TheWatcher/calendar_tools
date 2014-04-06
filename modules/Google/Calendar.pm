## @file
# This file contains the implementation of the Google calendar facilities
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class
# This class encapsulates operations involving the Google Calendar API
package Google::Calendar;

use v5.12;

use base qw(Webperl::SystemModule);
use Webperl::Utils qw(path_join hash_or_hashref);

use DateTime;
use DateTime::Format::RFC3339;
use JSON qw(decode_json);
use List::Util qw(first);
use List::MoreUtils qw(first_index);
use Scalar::Util qw(blessed);
use URI;

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(minimal    => 1,
                                        apiurl     => 'https://www.googleapis.com/calendar/v3/calendars',
                                        shortdays  => ["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
                                        formats    => { day     => "%a, %d %b %Y",
                                                        longday => "%A, %d %B %Y",
                                                        time    => "%H:%M",
                                                        at      => " at %H:%M",
                                        },
                                        strings    => { allday   => "All day",
                                                        starting => "Starting at ",
                                                        from     => "From ",
                                                        to       => " to ",
                                                        unknown  => "Unknown time",
                                        },
                                        @_)
        or return undef;

    return Webperl::SystemModule::set_error("No Google OAuth2 aware UserAgent provided")
        if(!$self -> {"agent"});

    return $self;
}


# =============================================================================
#  Google interaction code

## @method $ events_list(%args)
# Fetch a list of events from a Google calendar.
#
# Supported arguments are:
#
# - `calendarId`: required, ID of the calendar to fetch events for.
# - `orderBy`: the order to return events in, can be 'startTime' (the default) or 'updated'.
# - `singleEvents`:  expand recurring events into instances and only return single one-off
#   events and instances of recurring events. Defaults to "true".
# - `timeMin`: optional lower bound (inclusive) for an event's end time to filter by.
# - `timeMax`: optional upper bound (exclusive) for an event's start time to filter by.
# - `pageToken`: optional token specifying the page of results to return.
# - `maxResults`: optional maximum number of events to return.
#
# The response hash contains the following keys:
#
# - `events`: A reference to an array of Event resources
# - `nextpage`: The next page token to pass to the API. Not included if there are no more pages.
# - `start`: A human readable (not ISO8601/RCF3339) string containing the start date.
#            Note that ongoing events may start before this.
# - `startdate`: A DateTime object representing the start of the list.
# - `end`: A human readable (not ISO8601/RCF3339) string containing the end date.
#            Note that ongoing events may end after this.
# - `enddate`: A DateTime object representing the end of the list.
#
# @param args A hash, or reference to a hash, containing the args to set.
# @return A reference to a hash containing the response
sub events_list {
    my $self = shift;
    my $args = hash_or_hashref(@_);

    $self -> clear_error();

    my $output = {};
    my $nextpage = undef;

    # Issue the query
    do {
        my $query  = $self -> _build_list_query($args);
        my $result = $self -> {"agent"} -> get($query);

        return $self -> self_error("Google API request failed: ".$result -> status_line)
            unless($result -> is_success);

        # convert the json to a hash
        my $decoded = decode_json($result -> content());

        # Convert fields in the response into something usable, and then merge into
        # the accumulated data.
        my $response = $self -> _build_list_response($args, $decoded);
        $self -> merge_events($output, $response);

        $args -> {"pageToken"} = $response -> {"nextpage"};
    } while($args -> {"pageToken"});

    return $output;
}


## @method $ request_events_as_days($calid, $days, $from)
# Request a list of events for the specified number of days, and convert the
# result to a hash of date-keyed days, with each value being the list of
# events on that day.
#
# @param calid The ID of the calendar to fetch events from.
# @param days  The number of days of events to fetch.
# @param from  The date to start fetching events from. This can either be a
#              ISO8601 datestamp, an offset in days from the current day,
#              or a day of the week. If the latter is used, the /nearest/
#              day of the week is used. eg: if set to 'Fri' and the current
#              day is Monday, the previous Friday is used. This defaults to
#              1 (ie: from tomorrow);
# @return A reference to a hash of days, each day listing the events on that day.
sub request_events_as_days {
    my $self  = shift;
    my $calid = shift;
    my $days  = shift;
    my $from  = shift;

    $self -> clear_error();

    $from = 1 if(!defined($from));

    # Calculate the request dates. Ensture that the start is truncated to the day
    my $startdate = $self -> _make_datetime($from) -> truncate(to => 'day');

    # Enddate is exclusive, so just add 1 to the day
    my $enddate   = $startdate -> clone() -> add(days => $days + 1);

    my $events = $self -> events_list(calendarId => $calid,
                                      timeMin    => $startdate,
                                      timeMax    => $enddate)
        or return undef;

    my $result = { start     => $events -> {"start"},
                   startdate => $events -> {"startdate"},
                   reqstart  => $startdate,
                   end       => $events -> {"end"},
                   enddate   => $events -> {"enddate"},
                   reqend    => $enddate,
    };

    foreach my $event (@{$events -> {"events"}}) {
        # Determine which day this event belongs on
        my $date = $self -> _start_to_date($event -> {"start"});
        if(!$date) {
            warn "No date specified for event '".$event -> {"summary"}."\n";
            next;
        }

        # convert the day to a DateTime object as it is needed below
        my $daydate = $self -> _parse_datestring($date);

        # Build datetime objects and other information for the event
        $self -> _make_datetimes($event);

        # Nice version of the event start/end string
        $event -> {"timestring"} = $self -> _make_time_string($event -> {"start"}, $event -> {"end"}, $daydate);

        # Store the event
        push(@{$result -> {"days"} -> {$date} -> {"events"}}, $event);

        # Build a day name if not already done
        $result -> {"days"} -> {$date} -> {"name"} -> {"long"} = $daydate -> strftime($self -> {"formats"} -> {"longday"})
            if(!$result -> {"days"} -> {$date} -> {"name"} -> {"long"});

        $result -> {"days"} -> {$date} -> {"name"} -> {"short"} = $daydate -> strftime($self -> {"formats"} -> {"day"})
            if(!$result -> {"days"} -> {$date} -> {"name"} -> {"short"});

        # store the date date for later
        $result -> {"days"} -> {$date} -> {"date"} = $daydate;
    }

    return $result;
}


# =============================================================================
#  Event hash wrangling


## @method void merge_events($primary, $secondary)
# Merge events in the secondary events hash into the primary events hash. This will
# take any events in the secondary hash that do not appear in the primary and add
# them to the primary, performing ordering as needed. This updates the primary
# hash 'in place'.
#
# @param primary   The primary events hash.
# @param secondary The secondary events hash.
sub merge_events {
    my $self      = shift;
    my $primary   = shift;
    my $secondary = shift;

    push(@{$primary -> {"events"}}, @{$secondary -> {"events"}});

    $primary -> {"startdate"} = $secondary -> {"startdate"}
        if(!$primary -> {"startdate"} || $secondary -> {"startdate"} < $primary -> {"startdate"});

    $primary -> {"enddate"} = $secondary -> {"enddate"}
        if(!$primary -> {"enddate"} || $secondary -> {"enddate"} > $primary -> {"enddate"});

    # Convert the dates to strings
    $primary -> {"start"} = $primary -> {"startdate"} -> strftime($self -> {"formats"} -> {"day"});
    $primary -> {"end"}   = $primary -> {"enddate"} -> strftime($self -> {"formats"} -> {"day"});

    $primary -> {"nextpage"} = $secondary -> {"nextpage"};
}



## @method $ merge_day_events($primary, $secondary)
# Merge events in the secondary events hash into the primary events hash. This will
# take any events in the secondary hash that do not appear in the primary and add
# them to the primary, performing ordering as needed. This updates the primary
# hash 'in place'.
#
# @param primary   The primary events hash.
# @param secondary The secondary events hash.
# @return A reference to the primary hash with the new elements.
sub merge_day_events {
    my $self      = shift;
    my $primary   = shift;
    my $secondary = shift;

    # Begin by merging the hash of days in the seconday into the primary
    foreach my $date (keys(%{$secondary -> {"days"}})) {
        # This should never actually be needed, all keys in the hash should be dates, but check anyway
        next unless($date =~ /^\d{4}-\d{2}-\d{2}$/);

        # If there is no data in the primary for this day, just use it
        if(!$primary -> {"days"} -> {$date}) {
            $primary -> {"days"} -> {$date} = $secondary -> {"days"} -> {$date};

        # primary contains data for the same date, merge the list of events
        } else {
            # Go through the list of events in the seconday, looking for events that
            # are not in the primary. Add any events that are not in the primary
            my $resort = 0;
            foreach my $event (@{$secondary -> {"days"} -> {$date} -> {"events"}}) {
                if(!first { $_ -> {"id"} eq $event -> {"id"} } @{$primary -> {"days"} -> {$date} -> {"events"}}) {
                    push(@{$primary -> {"days"} -> {$date} -> {"events"}}, $event);
                    $resort = 1;
                }
            }

            # Re-sort the primary event list if needed
            if($resort) {
                my @sorted = sort _event_compare @{$primary -> {"days"} -> {$date} -> {"events"}};
                $primary -> {"days"} -> {$date} -> {"events"} = \@sorted;
            }
        }
    }

    # Now handle start and end dates. Comparison works for the *date values as they're DateTime
    $primary -> {"startdate"} = $secondary -> {"startdate"}
        if(!$primary -> {"startdate"} || $secondary -> {"startdate"} < $primary -> {"startdate"});

    $primary -> {"enddate"} = $secondary -> {"enddate"}
        if(!$primary -> {"enddate"} || $secondary -> {"enddate"} > $primary -> {"enddate"});

    $primary -> {"reqstart"} = $secondary -> {"reqstart"}
        if(!$primary -> {"reqstart"} || $secondary -> {"reqstart"} < $primary -> {"reqstart"});

    $primary -> {"reqend"} = $secondary -> {"reqend"}
        if(!$primary -> {"reqend"} || $secondary -> {"reqend"} > $primary -> {"reqend"});

    # Convert the dates to strings
    $primary -> {"start"} = $primary -> {"startdate"} -> strftime($self -> {"formats"} -> {"day"});
    $primary -> {"end"}   = $primary -> {"enddate"} -> strftime($self -> {"formats"} -> {"day"});

    return $primary;
}


# =============================================================================
#  Private google code

## @method private $ _build_list_query($args)
# Generate the query URI to use when sending an events list request to the API.
# Supported arguments are:
#
# - `calendarId`: required, ID of the calendar to fetch events for.
# - `orderBy`: the order to return events in, can be 'startTime' (the default) or 'updated'.
# - `singleEvents`:  expand recurring events into instances and only return single one-off
#   events and instances of recurring events. Defaults to "true".
# - `timeMin`: optional lower bound (inclusive) for an event's end time to filter by.
# - `timeMax`: optional upper bound (exclusive) for an event's start time to filter by.
# - `pageToken`: optional token specifying the page of results to return.
# - `maxResults`: optional maximum number of events to return.
#
# @param args A reference to a hash containing the args to set.
# @return A reference to a URI object containing the query.
sub _build_list_query {
    my $self = shift;
    my $args = shift;

    # Basic always-defined-some-way arguments
    my $query = { orderBy      => $args -> {"orderBy"} || "startTime",
                  singleEvents => $args -> {"singleEvents"} || "true" };

    # Hande time ranges
    $query -> {"timeMin"} = $self -> _make_datetime($args -> {"timeMin"}, 1)
        if(defined($args -> {"timeMin"}));
    $query -> {"timeMax"} = $self -> _make_datetime($args -> {"timeMax"}, 1)
        if(defined($args -> {"timeMax"}));

    # Is this a paged query?
    $query -> {"pageToken"} = $args -> {"pageToken"}
        if($args -> {"pageToken"});

    # Is there a count limit?
    $query -> {"maxResults"} = $args -> {"maxResults"}
        if($args -> {"maxResults"});

    # Build the url with the query
    my $url = URI -> new(path_join($self -> {"apiurl"}, $args -> {"calendarId"}, 'events'));
    $url -> query_form($query);

    return $url;
}


## @method private $ _build_list_response($args, $apidata)
# Generate the response hash containing the data returned from the API. The
# response hash contains the following keys:
#
# - `events`: A reference to an array of Event resources
# - `nextpage`: The next page token to pass to the API. Not included if there are no more pages.
# - `start`: A human readable (not ISO8601/RCF3339) string containing the start date.
#            Note that ongoing events may start before this.
# - `startdate`: A DateTime object representing the start of the list.
# - `end`: A human readable (not ISO8601/RCF3339) string containing the end date.
#            Note that ongoing events may end after this.
# - `enddate`: A DateTime object representing the end of the list.
#
# @param args    A reference to a hash containing the args used to generate the API response.
# @param apidata A reference to a hash containing the data returned from the API.
# @return A reference to a hash containing the response.
sub _build_list_response {
    my $self    = shift;
    my $args    = shift;
    my $apidata = shift;
    my ($startdate, $enddate);

    # Did the args include start or end dates? If so, use them
    $startdate = $self -> _make_datetime($args -> {"timeMin"})
        if(defined($args -> {"timeMin"}));
    $enddate = $self -> _make_datetime($args -> {"timeMax"})
        if(defined($args -> {"timeMax"}));

    # If there's no start or end date specified, try to work them out from the
    # data returned from the api. Which is fun.
    if(scalar(@{$apidata -> {"items"}})) {
        $startdate = $self -> _fetch_datetime($apidata -> {"items"} -> [0] -> {"start"});
        $enddate   = $self -> _fetch_datetime($apidata -> {"items"} -> [-1] -> {"end"});
    }

    my $result = { events => $apidata -> {"items"} };

    $result -> {"nextpage"} = $apidata -> {"nextPageToken"}
        if($apidata -> {"nextPageToken"});

    if($startdate) {
        $result -> {"start"}     = $startdate -> strftime($self -> {"formats"} -> {"day"});
        $result -> {"startdate"} = $startdate;
    }

    if($enddate) {
        $result -> {"end"}     = $enddate -> strftime($self -> {"formats"} -> {"day"});
        $result -> {"enddate"} = $enddate;
    }

    return $result;
}


## @method private $ _fetch_datetime($datetime)
#
#
# @return A DateTime object representing the specified date.
sub _fetch_datetime {
    my $self     = shift;
    my $datetime = shift;

    return undef if(!defined($datetime));

    # Handle situations where the event is all day (just a date) or timed (dateTime)
    return $self -> _parse_datestring($datetime -> {"date"} || $datetime -> {"dateTime"});
}


# =============================================================================
#  Private date handling code

## @method private $ _start_to_date($start)
# Given a 'start' reference, determine which date this actually belongs in.
#
# @param start A refrence to a hash containing the start date or datetime.
# @return The date to store the event in, in the form YYYY-MM-DD, Undef on error.
sub _start_to_date {
    my $self   = shift;
    my $start  = shift;

    return $self -> self_error("No start date provided")
        if(!defined($start));

    my $date = $start -> {"date"} || $start -> {"dateTime"};
    my ($realdate) = $date =~ /^(\d{4}-\d{2}-\d{2})/;

    return $realdate;
}


## @method private $ parse_datestring($datestr)
# Parse the specified date string into a new DateTime object.
#
# @param datestr The ISO8601 date to parse.
# @return A new DateTime object.
sub _parse_datestring {
    my $self    = shift;
    my $datestr = shift;

    my ($year, $month, $day, $hour, $minute, $second, $tz) = $datestr =~ /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}):(\d{2})(.*))?$/;

    # Fix up the 'Z' marker for UTC
    $tz = "UTC" if($tz && $tz eq "Z");

    return DateTime -> new(formatter => DateTime::Format::RFC3339 -> new(),
                           year      => $year,
                           month     => $month,
                           day       => $day,
                           hour      => $hour || 0,
                           minute    => $minute || 0,
                           second    => $second || 0,
                           time_zone => $tz || "UTC");
}


## @method private $ _same_day($datea, $dateb)
# Determine whether the two specified dates represent times within the same day.
# This attempts to check whether the days in datea and dateb match, accounting
# for time zone differences as needed.
#
# @param datea The first date to check.
# @param dateb The second date to check.
# @return true if the dates represent times within the same day, false otherwise.
sub _same_day {
    my $self  = shift;
    my $datea = shift;
    my $dateb = shift;

    # force days into the same time zone - God, how I hate DST.
    my $daya = $datea -> clone() -> set_time_zone("UTC") -> truncate(to => 'day');
    my $dayb = $dateb -> clone() -> set_time_zone("UTC") -> truncate(to => 'day');

    return !DateTime -> compare($daya, $dayb);
}


## @method private $ _human_time($datetime, $current, $notime)
# Convert the specified datetime to a human-readable format. This produces a
# string whose formatting depends on whether the specified datetime is on
# the same day as the specified current date, and whether no time should
# be included in the string.
#
# @param datetime The DateTime object to convert to a string.
# @param current  A DateTime object representing the current date.
# @param notime   If set to true, no time is included in the output.
# @return A string version of the specified datetime.
sub _human_time {
    my $self     = shift;
    my $datetime = shift;
    my $current  = shift;
    my $notime   = shift;

    if($self -> _same_day($datetime, $current)) {
        if($notime) {
            return $datetime -> strftime($self -> {"formats"} -> {"day"});
        } else {
            return $datetime -> strftime($self -> {"formats"} -> {"time"});
        }
    } else {
        return $datetime -> strftime($self -> {"formats"} -> {"day"}.($notime ? "" : $self -> {"formats"} -> {"at"}));
    }
}


## @method private $ _make_time_string($start, $end, $current)
# Given a start and end hash, determine whether the event is all day, or if
# it has a set period, and generate an appropriate string for the times.
#
# @param start A reference to a hash containing either a date or dateTime element.
# @param end   A reference to a hash containing either a date or dateTime element.
# @return A string describing the start and end times.
sub _make_time_string {
    my $self    = shift;
    my $start   = shift;
    my $end     = shift;
    my $current = shift;

    return $self -> {"strings"} -> {"allday"}
        if(!$start);

    my $startdate = $self -> _parse_datestring($start -> {"date"} || $start -> {"dateTime"});
    my $enddate   = $self -> _parse_datestring($end   -> {"date"} || $end   -> {"dateTime"});

    # If the event is all day or multi-day all-day, the end day is set to the next day.
    $enddate -> add(days => -1)
        if($start -> {"date"} && !$start -> {"dateTime"} && $end -> {"date"} && !$end -> {"dateTime"});

    given(DateTime -> compare($startdate, $enddate)) {
        when(0)  { return $self -> {"strings"} -> {"allday"}}
        when(1)  { return $self -> {"strings"} -> {"starting"}.$self -> _human_time($startdate, $current, $start -> {"date"}) }
        when(-1) { return $self -> {"strings"} -> {"from"}.$self -> _human_time($startdate, $current, $start -> {"date"}).
                          $self -> {"strings"} -> {"to"}.$self -> _human_time($enddate, $current, $end -> {"date"})
        }
    }

    return $self -> {"strings"} -> {"unknown"};
}


sub _make_datetimes {
    my $self  = shift;
    my $event = shift;

    $event -> {"start"} -> {"DateTimeObj"} = $self -> _parse_datestring($event -> {"start"} -> {"date"} || $event -> {"start"} -> {"dateTime"});
    $event -> {"end"}   -> {"DateTimeObj"} = $self -> _parse_datestring($event -> {"end"}   -> {"date"} || $event -> {"end"}  -> {"dateTime"});

    my $adjusted = $event -> {"end"} -> {"DateTimeObj"} -> clone();

    # If the event is all day or multi-day all-day, the end day is set to the next day.
    if($event -> {"start"} -> {"date"} && !$event -> {"start"} -> {"dateTime"} &&
       $event -> {"end"} -> {"date"}   && !$event -> {"end"} -> {"dateTime"}) {
        $event -> {"end"} -> {"DateTimeObj"} -> add(seconds => -1);

        # Work out 'all day' marker.
        $adjusted -> add(days => -1);
        $event -> {"allday"} = (DateTime -> compare($event -> {"start"} -> {"DateTimeObj"}, $adjusted) == 0);
    }

}

# =============================================================================
#  Private 'from' day related code

## @method private $ _make_weekday($day, $next)
# Build a DateTime object representing the previous or next weekday specified.
# This will find the previous or next occurance of the specified weekday from
# the current day and return a DateTime object for that day. If the weekday
# requested is the current day, the returned object represents will be the
# previous or next weekday.
#
# @param day  The day of the week, must be a lowercase abbreviated version of the
#             weekday required.
# @param next If set to true this finds the next occurance of the weekday,
#             otherwise it finds the previous one.
# @return A DateTime object representing the weekday on success, undef on error.
sub _make_weekday {
    my $self = shift;
    my $day  = shift;
    my $next = shift;

    # Work out what the current day is
    my $today  = DateTime -> today(time_zone => "UTC");
    my $nowdow = $today -> day_of_week_0();

    # Work out what the requested day of the week is
    my $targdow = first_index { $_ eq $day } @{$self -> {"shortdays"}};
    return $self -> self_error("Unable to convert '$day' to a day of the week")
        if($targdow == -1);

    # How far off the target day are we?
    my $diff = $targdow - $nowdow;

    # Handle wraparound
    $diff -= 7 if(!$next && $diff >= 0);
    $diff += 7 if($next && $diff <= 0);

    # Tweak the current day back to the target
    return $today -> add(days => $diff);
}


## @method private $ _make_daydesc($daystr)
# Given a weekday name, optionally preceeded by a -, produce a hash containing
# a flag indicating whether the day should be the previous weekday or the next,
# and the lowercase, abbreviated weekday name.
#
# @param daystr The day string to parse
# @return A reference to the day description on success, undef if the day in
#         the daystr is not recognised as a valid weekday.
sub _make_daydesc {
    my $self    = shift;
    my $daystr  = shift;
    my $daydesc = {};

    if($daystr =~ /^-/) {
        $daydesc -> {"previous"} = 1;
        $daystr =~ s/^-//;
    }

    $daystr = lc(substr($daystr, 0, 3));
    if($daystr ~~ $self -> {"shortdays"}) {
        $daydesc -> {"day"} = $daystr;
        return $daydesc;
    }

    return undef;
}


## @method private $ _make_datetime($from, $asstr)
# Given a 'from' description, which may either be a positive or negative number,
# an ISO8601 datestamp, or a weekday name (optionally preceeded by -), produce a
# DateTime object representing the day to fetch entries from.
#
# @param from  The from date description string
# @param asstr If true, the date is returned as a string rather than a DateTime object.
# @return A DateTime object. If the from string is not valid, this will return
#         a DateTime object for the current day.
sub _make_datetime {
    my $self  = shift;
    my $from  = shift;
    my $asstr = shift;

    my $datetime;
    given($from) {
        # Is the argument already a DateTime object? If so, create a clone for safety
        when($self -> _is_datetime($from)) {
            $datetime = $from -> clone();

            # Force RFC3339 formatter
            $datetime -> set_formatter(DateTime::Format::RFC3339 -> new());
        }

        # Is the argument an offset from the current day
        when(/^(-?\d+)$/) {
            $datetime = DateTime -> today(time_zone => "UTC", formatter => DateTime::Format::RFC3339 -> new()) -> add(days => $1);
        }

        # Is the argument an ISO8601 date/datetime?
        when(/^\d{4}-\d{2}-\d{2}(?:t\d{2}:\d{2}:\d{2})?/) {
            $datetime = $self -> _parse_datestring($from);
        }

        # Is the argument an absolute epoch datetime?
        when(/^=(\d+)$/) {
            $datetime = DateTime -> from_epoch(epoch => $1, time_zone => "UTC", formatter => DateTime::Format::RFC3339 -> new());
        }

        # Try parsing it as a day description
        default {
            my $daydesc = $self -> _make_daydesc($from);
            $datetime = $self -> _make_weekday($daydesc -> {"day"}, !$daydesc -> {"previous"})
                if($daydesc);
        }
    }

    # If there's still no datetime here, fall back on today.
    $datetime = DateTime -> today(time_zone => "UTC", formatter => DateTime::Format::RFC3339 -> new())
        if(!$datetime);

    return $asstr ? "$datetime" : $datetime;
}


## @method $ _is_datetime($arg)
# Determine whether the provided argument is a DateTime object or not.
#
# @param arg The scalar to check.
# @return true if the arg is a DateTime object, false otherwise
sub _is_datetime {
    my $self = shift;
    my $arg  = shift;

    return (blessed $arg && $arg -> isa('DateTime'));
}


# =============================================================================
#  Merge support

## @fn $ _event_compare(void)
# A sort comparator function that compares two events.
#
sub _event_compare {
    my $astart = $a -> {"start"} -> {"date"} || $a -> {"start"} -> {"dateTime"};
    my $bstart = $b -> {"start"} -> {"date"} || $b -> {"start"} -> {"dateTime"};
    my $aend   = $a -> {"end"} -> {"date"} || $a -> {"end"} -> {"dateTime"};
    my $bend   = $b -> {"end"} -> {"date"} || $b -> {"end"} -> {"dateTime"};

    # If the dates and times match, go off summary
    return $astart cmp $bstart || $aend cmp $bend || $a -> {"summary"} cmp $b -> {"summary"};
}


1;
