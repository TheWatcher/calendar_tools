#!/usr/bin/perl

use strict;
use v5.12;

our ($scriptpath, $config);

# Work out where the script is running from
use FindBin;
BEGIN {
    $ENV{"PATH"} = "/bin:/usr/bin"; # safe path.

    # $FindBin::Bin is tainted by default, so we may need to fix that
    # NOTE: This may be a potential security risk, but the chances
    # are honestly pretty low...
    if ($FindBin::Bin =~ /(.*)/) {
        $scriptpath = $1;
    }
}

use lib qw(/var/www/webperl);
use Webperl::ConfigMicro;
use Webperl::Utils qw(path_join);
use DateTime;
use DateTime::Format::RFC3339;
use LWP::Authen::OAuth2;
use JSON qw(decode_json);
use URI;

use Data::Dumper;


# =============================================================================
#  Google interaction code

## @fn void save_tokens($token)
# Save the tokens provided by Google to the configuration file. This is a
# callback used by the OAuth2 handler to support automated saving of the
# tokens provided by google.
#
# @param token The token string to save to the configuration file.
sub save_tokens {
    my $token = shift;

    $config -> {"google"} -> {"token"} = $token;
    $config -> write(path_join($scriptpath, "config", "config.cfg"))
        or die "Unable to write configuration: ".$config -> errstr()."\n";
}


## @fn $ request_events($agent, $settings, $days)
# Request the events for the next 'days' days, starting at the next 00:00
# and going through to 23:59:59 'days' days later.
#
# @param agent    The agent to issue queries through. Must be authenticated and
#                 have at least read permission to the calendar.
# @param settings A reference to the configutation object.
# @param days     The number of days of events to fetch.
sub request_events {
    my $agent    = shift;
    my $settings = shift;
    my $days     = shift;

    # Calculate the request dates
    my $tomorrow = DateTime -> today(time_zone => "UTC", formatter => DateTime::Format::RFC3339 -> new()) -> add(months => 5);
    my $enddate  = $tomorrow -> clone() -> add(days => $days, hours => 23, minutes => 59, seconds => 59);

    my $url = URI -> new('https://www.googleapis.com/calendar/v3/calendars/'.$settings -> {"calendar"} -> {"id"}.'/events');
    $url -> query_form( [ orderBy      => "startTime",
                          singleEvents => "true",
                          timeMin      => "$tomorrow",
                          timeMax      => "$enddate" ]);

    my $result = $agent -> get($url);
    die "Google API request failed: ".$result -> status_line."\n"
        unless($result -> is_success);

    return decode_json($result -> content());
}


# =============================================================================
#  Date handling code

## @fn $ start_to_date($start)
# Given a 'start' reference, determine which date this actually belongs in.
#
# @param start A refrence to a hash containing the start date or datetime.
# @return The date to store the event in, in the form YYYY-MM-DD
sub start_to_date {
    my $start  = shift;

    return undef
        if(!defined($start));

    my $date = $start -> {"date"} || $start -> {"dateTime"};
    my ($realdate) = $date =~ /^(\d{4}-\d{2}-\d{2})/;

    return $realdate;
}


## @fn $ parse_datestring($datestr)
# Parse the specified date string into a new DateTime object.
#
# @param datestr The ISO8601 date to parse.
# @return A new DateTime object.
sub parse_datestring {
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


## @fn $ same_day($datea, $dateb)
# Determine whether the two specified dates represent times within the same day.
# This attempts to check whether the days in datea and dateb match, accounting
# for time zone differences as needed.
#
# @param datea The first date to check.
# @param dateb The second date to check.
# @return true if the dates represent times within the same day, false otherwise.
sub same_day {
    my $datea = shift;
    my $dateb = shift;

    # force days into the same time zone - God, how I hate DST.
    my $daya = $datea -> clone() -> set_time_zone("UTC") -> truncate(to => 'day');
    my $dayb = $dateb -> clone() -> set_time_zone("UTC") -> truncate(to => 'day');

    return !DateTime -> compare($daya, $dayb);
}


## @fn $ human_time($datetime, $current, $notime)
# Convert the specified datetime to a human-readable format. This produces a
# string whose formatting depends on whether the specified datetime is on
# the same day as the specified current date, and whether no time should
# be included in the string.
#
# @param datetime The DateTime object to convert to a string.
# @param current  A DateTime object representing the current date.
# @param notime   If set to true, no time is included in the output.
# @return A string version of the specified datetime.
sub human_time {
    my $datetime = shift;
    my $current  = shift;
    my $notime   = shift;

    if(same_day($datetime, $current)) {
        if($notime) {
            return $datetime -> strftime("%a, %d %b %Y");
        } else {
            return $datetime -> strftime("%H:%M");
        }
    } else {
        return $datetime -> strftime("%a, %d %b %Y".($notime ? "" : " at %H:%M"));
    }
}


## @fn $ make_time_string($start, $end, $current)
# Given a start and end hash, determine whether the event is all day, or if
# it has a set period, and generate an appropriate string for the times.
#
# @param start A reference to a hash containing either a date or dateTime element.
# @param end   A reference to a hash containing either a date or dateTime element.
# @return A string describing the start and end times.
sub make_time_string {
    my $start   = shift;
    my $end     = shift;
    my $current = shift;

    return "All day"
        if(!$start);

    my $startdate = parse_datestring($start -> {"date"} || $start -> {"dateTime"});
    my $enddate   = parse_datestring($end   -> {"date"} || $end   -> {"dateTime"});

    given(DateTime -> compare($startdate, $enddate)) {
        when(0)  { return "All day" };
        when(1)  { return "Starting at ".human_time($startdate, $current, $start -> {"date"}) };
        when(-1) { return "From ".human_time($startdate, $current, $start -> {"date"})." to ".human_time($enddate, $current, $end -> {"date"}) };
    }

    return "Unknown time";
}


# =============================================================================
#  Event handling code

## @fn $ events_to_days($events)
# Given a list of events, convert them to a hash of date-keyed days, with
# each value being the list of events on that day.
#
# @param events A reference to an array of events/
# @return A reference to a hash of days, each day listing the events on that day.
sub events_to_days {
    my $events = shift;
    my $days   = {};

    foreach my $event (@{$events}) {
        # Determine which day this event belongs on
        my $date = start_to_date($event -> {"start"});
        if(!$date) {
            warn "No date specified for event '".$event -> {"summary"}."\n";
            next;
        }

        # Store the event
        push(@{$days -> {$date}}, $event);
    }

    return $days;
}


sub generate_days {
    my $days = shift;

    foreach my $day (sort keys(%{$days})) {
        # convert the date to something nicer
        my $dayfull = parse_datestring($day);

        my $daystr = $dayfull -> strftime("%A, %d %B %Y");
        print $daystr."\n".("-" x length($daystr))."\n";

        foreach my $event (@{$days -> {$day}}) {
            print $event -> {"summary"}."\n";
            print "\t".make_time_string($event -> {"start"}, $event -> {"end"}, $dayfull)."\n";
            print "\tLocation: ".$event -> {"location"}."\n" if($event -> {"location"});
            print "\n";
        }
    }
}


$config = Webperl::ConfigMicro -> new(path_join($scriptpath, "config", "config.cfg"), quote_values => '')
    or die "Unable to load configuration: ".$Webperl::SystemModule::errstr;

my $agent = LWP::Authen::OAuth2->new(client_id        => $config -> {"google"} -> {"client_id"},
                                     client_secret    => $config -> {"google"} -> {"client_secret"},
                                     service_provider => "Google",
                                     redirect_uri     => $config -> {"google"} -> {"redirect_uri"},

                                     # Optional hook, but recommended.
                                     save_tokens      => \&save_tokens,

                                     # This is for when you have tokens from last time.
                                     token_string     => $config -> {"google"} -> {"token"},
                                     scope            => $config -> {"google"} -> {"scope"},

                                     flow => "web server",
                 );

my $events = request_events($agent, $config, $config -> {"notify"} -> {"days"});

die "No events returned for requested period.\n"
    if(!$events -> {"items"} || !scalar(@{$events -> {"items"}}));

my $day_events = events_to_days($events -> {"items"});
generate_days($day_events);
