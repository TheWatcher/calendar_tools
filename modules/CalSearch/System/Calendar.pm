# This file contains the implementation of the calendar handling engine.
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
# This class encapsulates operations involving calendars in the system.
package CalSearch::System::Calendar;

use strict;
use base qw(Webperl::SystemModule);
use LWP::Authen::OAuth2;
use Google::Calendar;


## @fn void save_tokens($token, $dbh, $settings)
# Save the tokens provided by Google to the configuration file. This is a
# callback used by the OAuth2 handler to support automated saving of the
# tokens provided by google.
#
# @param token The token string to save to the configuration file.
sub save_tokens {
    my $token    = shift;
    my $dbh      = shift;
    my $settings = shift;

    my $confh = $dbh -> prepare("UPDATE `".$settings -> {"database"} -> {"settings"}."`
                                 SET `value` = ? WHERE `name` = 'google:token'");
    my $rows = $confh -> execute($token);
    die "Unable to update API token: ".$dbh -> errstr."\n" if(!$rows);
    die "API token update failed: no rows updated\n" if($rows eq "0E0");
}


# ==============================================================================
#  Creation

## @cmethod $ new(%args)
# Create a new Events object to manage calendar allocation and lookup.
# The minimum values you need to provide are:
#
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object
# * logger    - The system logger object.
#
# @param args A hash of key value pairs to initialise the object with.
# @return A new Events object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    $self -> {"agent"} = LWP::Authen::OAuth2 -> new(client_id        => $self -> {"settings"} -> {"config"} -> {"google:client_id"},
                                                    client_secret    => $self -> {"settings"} -> {"config"} -> {"google:client_secret"},
                                                    service_provider => "Google",
                                                    redirect_uri     => $self -> {"settings"} -> {"config"} -> {"google:redirect_uri"},

                                                    # Optional hook, but recommended.
                                                    save_tokens      => \&save_tokens,
                                                    save_tokens_args => [ $self -> {"dbh"}, $self -> {"settings"} ],

                                                    # This is for when you have tokens from last time.
                                                    token_string     => $self -> {"settings"} -> {"config"} -> {"google:token"},
                                                    scope            => $self -> {"settings"} -> {"config"} -> {"google:scope"},

                                                    flow => "web server");

    $self -> {"api"} = Google::Calendar -> new(agent    => $self -> {"agent"},
                                               settings => $self -> {"settings"})
        or return Webperl::SystemModule::set_error("Unable to create calendar object: ".$Webperl::SystemModule::errstr);

    return $self;
}


# ==============================================================================
#  API wrapper


## @method $ get_calendar_info($calendarid)
# Use the Google API to fetch the title and description for the calendar with the specified ID.
#
# @param calendarid The ID of the calendar to fetch.
# @return A reference to a hash containing the title and description on success,
#         undef on error.
sub get_calendar_info {
    my $self       = shift;
    my $calendarid = shift;

    $self -> clear_error();

    my $resp = $self -> {"api"} -> calendar_info($calendarid)
        or return $self -> self_error("Unable to fetch information for this calendar");

    return { "title"       => $resp -> {"summary"},
             "description" => $resp -> {"description"} };
}


# ==============================================================================
#  Database related

## @method $ get_user_calendars($userid)
# Fetch the list of calendars the user has added.
#
# @param userid The ID of the user to fetch the calendar list for
# @return A reference to an array of calendar sources on success, undef on error.
#         This will return an empty array ref if the user has no calendars set.
sub get_user_calendars {
    my $self   = shift;
    my $userid = shift;

    $self -> clear_error();

    my $cals = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"calendars"}."`
                                            WHERE `user_id` = ?
                                            ORDER BY `title`, `last_import`");
    $cals -> execute($userid)
        or return $self -> self_error("Unable to execute user calendar lookup: ".$self -> {"dbh"} -> errstr);

    return $cals -> fetchall_arrayref({});
}


1;
