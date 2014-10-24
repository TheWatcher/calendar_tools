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
use Digest;
use MIME::Base64;
use Crypt::Random qw(makerandom);

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
    my $self     = $class -> SUPER::new("scope"   => "https://www.googleapis.com/auth/calendar.readonly",
                                        "user_id" => undef,
                                        @_)
        or return undef;

    $self -> {"token"} = $self -> _get_user_token();

    $self -> {"agent"} = LWP::Authen::OAuth2->new(client_id        => $self -> {"settings"} -> {"config"} -> {"google:client_id"},
                                                  client_secret    => $self -> {"settings"} -> {"config"} -> {"google:client_secret"},
                                                  service_provider => "Google",
                                                  redirect_uri     => $self -> {"settings"} -> {"config"} -> {"google:redirect_uri"},
                                                  scope            => $self -> {"scope"},
                                                  flow             => "web server",
                                                  access_type      => "offline",
                                                  approval_prompt  => "force",

                                                  # Optional hook, but recommended.
                                                  save_tokens      => \&_save_tokens,
                                                  save_tokens_args => [ $self -> {"dbh"}, $self -> {"settings"}, $self -> {"logger"}, $self -> {"user_id"} ],

                                                  # This is for when you have tokens from last time.
                                                  token_string     => $self -> {"token"},
        );

    $self -> {"api"} = Google::Calendar -> new(agent    => $self -> {"agent"},
                                               settings => $self -> {"settings"})
        or die "Unable to create calendar object\n";

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

## @method $ user_has_token()
# Determine whether the current user has a Google API token string available, and
# if so attempt
sub user_has_token {
    my $self = shift;

    return(defined($self -> {"token"}) && $self -> {"token"});
}


## @method $ get_user_calendars()
# Fetch the list of calendars the user has added.
#
# @return A reference to an array of calendar sources on success, undef on error.
#         This will return an empty array ref if the user has no calendars set.
sub get_user_calendars {
    my $self   = shift;

    $self -> clear_error();

    my $cals = $self -> {"dbh"} -> prepare("SELECT * FROM `".$self -> {"settings"} -> {"database"} -> {"calendars"}."`
                                            WHERE `user_id` = ?
                                            ORDER BY `title`, `last_import`");
    $cals -> execute($self -> {"user_id"})
        or return $self -> self_error("Unable to execute user calendar lookup: ".$self -> {"dbh"} -> errstr);

    return $cals -> fetchall_arrayref({});
}


## @method private $ _get_csrf_token()
# Fetch the anti Cross-Site Request Forgery token for the specified user. This
# will obtain the users CSRF token, creating one if the user does not have one.
#
# @return The CSRF token string on success, undef on error.
sub get_csrf_token {
    my $self = shift;

    $self -> clear_error();

    my $csrf = $self -> _get_user_csrf();
    return undef unless(defined($csrf)); # undef return means an error occurred
    return $csrf if($csrf);              # return the token if there is one

    $csrf = $self -> _make_user_csrf();
    return undef unless(defined($csrf)); # undef return means an error occurred
    return $csrf;
}



# ==============================================================================
#  Private internal madness

## @method private $ _get_user_token()
# Fetch the access token for the specified user from the database.
#
# @return The access token string on success, undef on error or if the
#         user has no token associated with their account.
sub _get_user_token {
    my $self   = shift;

    $self -> clear_error();

    my $userh = $self -> {"dbh"} -> prepare("SELECT `token`
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"user_tokens"}."`
                                             WHERE `user_id` = ?");
    $userh -> execute($self -> {"user_id"})
        or return $self -> self_error("Unable to look up user token: ".$self -> {"dbh"} -> errstr);

    my $usertoken = $userh -> fetchrow_arrayref();
    return $usertoken ? $usertoken -> [0] : undef;
}


## @method private $ _get_user_csrf()
# Fetch the csrf token for the specified user from the database.
#
# @return The csrf token string on success, undef on error, an
#         empty string if the user has no csrf token.
sub _get_user_csrf {
    my $self   = shift;

    $self -> clear_error();

    my $userh = $self -> {"dbh"} -> prepare("SELECT `csrf`
                                             FROM `".$self -> {"settings"} -> {"database"} -> {"user_tokens"}."`
                                             WHERE `user_id` = ?");
    $userh -> execute($self -> {"user_id"})
        or return $self -> self_error("Unable to look up user csrf: ".$self -> {"dbh"} -> errstr);

    my $usertoken = $userh -> fetchrow_arrayref();
    return $usertoken ? $usertoken -> [0] : "";
}


## @method private $ _make_user_csrf()
# Generate a csrf token for the specified user and store it in the database.
#
# @return The csrf token string on success, undef on error.
sub _make_user_csrf {
    my $self = shift;

    $self -> clear_error();

    # Generate the csrf token based on the userid, the time, and a 512 bit random number
    my $sha256 = Digest -> new("SHA-256");
    $sha256 -> add("userid:".$self -> {"user_id"}."-time:".time());
    $sha256 -> add(encode_base64(makerandom(Size => 512, Strength => 0), ""));
    my $csrf = $sha256 -> hexdigest();

    # And shove it into the database
    my $inserth = $self -> {"dbh"} -> prepare("INSERT INTO `".$self -> {"settings"} -> {"database"} -> {"user_tokens"}."`
                                               (`user_id`, `csrf`)
                                               VALUES (?, ?)
                                               ON DUPLICATE KEY UPDATE `csrf` = VALUES(`csrf`)");
    my $rows = $inserth -> execute($self -> {"user_id"}, $csrf);
    return $self -> self_error("Unable to update CSRF token: ".$self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("CSRF token update failed: no rows updated") if($rows eq "0E0");

    return $csrf;
}


## @fn void _save_tokens($token, $dbh, $settings, $logger, $userid)
# Save the tokens provided by Google to the configuration file. This is a
# callback used by the OAuth2 handler to support automated saving of the
# tokens provided by google.
#
# @param token    The token string to save to the configuration file.
# @param dbh      A reference to a database handle to issue queries through.
# @param settings A reference to the global settings data.
# @param logger   A reference to a logger object to record error messages.
# @param userid   The ID of the user who owns the token.
sub save_tokens {
    my $token    = shift;
    my $dbh      = shift;
    my $settings = shift;
    my $logger   = shift;
    my $userid   = shift;

    my $confh = $dbh -> prepare("INSERT INTO `".$settings -> {"database"} -> {"user_tokens"}."`
                                 (`user_id`, `token`)
                                 VALUES (?, ?)
                                 ON DUPLICATE KEY UPDATE `token` = VALUES(`token`)");
    my $rows = $confh -> execute($userid, $token);
    $logger -> die_log(undef, "Unable to update API token: ".$dbh -> errstr) if(!$rows);
    $logger -> die_log(undef, "API token update failed: no rows updated") if($rows eq "0E0");
}


1;
