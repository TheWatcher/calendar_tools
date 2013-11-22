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
use Webperl::Utils qw(path_join);

use DateTime;
use DateTime::Format::RFC3339;
use List::MoreUtils qw(first_index);
use JSON qw(decode_json);
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

## @method $ request_events($days, $from)
# Request the events for the next 'days' days.
#
# @param days The number of days of events to fetch.
# @param from The date to start fetching events from. This can either be a
#             ISO8601 datestamp, an offset in days from the current day,
#             or a day of the week. If the latter is used, the /nearest/
#             day of the week is used. eg: if set to 'Fri' and the current
#             day is Monday, the previous Friday is used. This defaults to
#             1 (ie: from tomorrow);
# @return A reference to a hash containing the events, start and end edate on
#         success, undef on error.
sub request_events {
    my $self = shift;
    my $days = shift;
    my $from = shift;

    $self -> clear_error();

    # Calculate the request dates. Ensture that the start is truncated to the day
    my $startdate = $self -> _make_from_datetime($from || "1") -> truncate(to => 'day');
    my $enddate   = $startdate -> clone() -> add(days => $days, hours => 23, minutes => 59, seconds => 59);

    my $url = URI -> new(path_join($self -> {"apiurl"}, $self -> {"settings"} -> {"calendar"} -> {"id"}, 'events'));
    $url -> query_form( [ orderBy      => "startTime",
                          singleEvents => "true",
                          timeMin      => "$startdate",
                          timeMax      => "$enddate" ]);

    my $result = $self -> {"agent"} -> get($url);

    return $self -> self_error("Google API request failed: ".$result -> status_line)
        unless($result -> is_success);

    my $decoded = decode_json($result -> content());
    return { events => $decoded -> {"items"},
             start  => $startdate -> strftime($self -> {"formats"} -> {"day"}),
             end    => $enddate -> strftime($self -> {"formats"} -> {"day"}) };
}


## @fn $ request_events_as_days($days, $from)
# Request a list of events for the specified number of days, and convert the
# result to a hash of date-keyed days, with each value being the list of
# events on that day.
#
# @return A reference to a hash of days, each day listing the events on that day.
sub request_events_as_days {
    my $self   = shift;
    my $days   = shift;
    my $from   = shift;

    $self -> clear_error();

    my $events = $self -> request_events($days, $from)
        or return undef;

    my $result = { start => $events -> {"start"},
                   end   => $events -> {"end"}
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

        # Nice version of the event start/end string
        $event -> {"timestring"} = $self -> _make_time_string($event -> {"start"}, $event -> {"end"}, $daydate);

        # Store the event
        push(@{$result -> {"days"} -> {$date} -> {"events"}}, $event);

        # Build a day name if not already done
        $result -> {"days"} -> {$date} -> {"name"} -> {"long"} = $daydate -> strftime($self -> {"formats"} -> {"longday"})
            if(!$result -> {"days"} -> {$date} -> {"name"} -> {"long"});

        $result -> {"days"} -> {$date} -> {"name"} -> {"short"} = $daydate -> strftime($self -> {"formats"} -> {"day"})
            if(!$result -> {"days"} -> {$date} -> {"name"} -> {"short"});

    }

    return $result;
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

    # If there's a start date with no datetime, and and end date with no datetime, and tne end is one day after the start,
    # it's actually an all day event
    if($start -> {"date"} && !$start -> {"dateTime"} && $end -> {"date"} && !$end -> {"dateTime"}) {
        my $nextday = $startdate -> clone() -> add(days => 1);
        return $self -> {"strings"} -> {"allday"}
            if($enddate eq $nextday);
    }

    given(DateTime -> compare($startdate, $enddate)) {
        when(0)  { return $self -> {"strings"} -> {"allday"}}
        when(1)  { return $self -> {"strings"} -> {"starting"}.$self -> _human_time($startdate, $current, $start -> {"date"}) }
        when(-1) { return $self -> {"strings"} -> {"from"}.$self -> _human_time($startdate, $current, $start -> {"date"}).
                          $self -> {"strings"} -> {"to"}.$self -> _human_time($enddate, $current, $end -> {"date"})
        }
    }

    return $self -> {"strings"} -> {"unknown"};
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


## @method private $ _make_from_datetime($from)
# Given a 'from' description, which may either be a positive or negative number,
# an ISO8601 datestamp, or a weekday name (optionally preceeded by -), produce a
# DateTime object representing the day to fetch entries from.
#
# @param from The from date description string
# @return A DateTime object. If the from string is not valid, this will return
#         a DateTime object for the current day.
sub _make_from_datetime {
    my $self = shift;
    my $from = shift;

    given($from) {
        when(/^(-?\d+)$/) {
            return DateTime -> today(time_zone => "UTC", formatter => DateTime::Format::RFC3339 -> new()) -> add(days => $1);
        }
        when(/^\d{4}-\d{2}-\d{2}(?:t\d{2}:\d{2}:\d{2})?/) {
            return $self -> _parse_datestring($from);
        }
        default {
            my $daydesc = $self -> _make_daydesc($from);
            return $self -> _make_weekday($daydesc -> {"day"}, !$daydesc -> {"previous"})
                if($daydesc);
        }
    }

    return DateTime -> today(time_zone => "UTC", formatter => DateTime::Format::RFC3339 -> new());
}


1;
