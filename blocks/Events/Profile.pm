## @file
# This file contains the implementation of the Events user profile.
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

## @class Events::Profile
package Events::Profile;

use strict;
use base qw(Events);
use v5.12;


## @method $ _generate_profile()
# Generate the content for the user profile page.
#
# @return Two strings, the first containing the page title, the second containing the
#         page content.
sub _generate_profile {
    my $self = shift;

    return ("", "");
}


## @method $ _generate_import()
# Generate the content for the user calendar import page.
#
# @return Two strings, the first containing the page title, the second containing the
#         page content.
sub _generate_import {
    my $self = shift;
    my $content = "";

    # Determine whether the user has a google API token
    if($self -> {"system"} -> {"calendar"} -> user_has_token()) {
        # Fetch the list of calendars the user has imported and convert to html
        my $calendars = $self -> {"system"} -> {"calendar"} -> get_user_calendars();
        my $callist = "";
        foreach my $calendar (@{$calendars}) {
            $callist .= $self -> {"template"} -> load_template("profile/calendars/entry.tem", {"***title***"       => $calendar -> {"title"},
                                                                                               "***description***" => $calendar -> {"description"},
                                                                                               "***startdate***"   => $calendar -> {"startdate"},
                                                                                               "***enddate***"     => $calendar -> {"enddate"},
                                                                                               "***startfmt***"    => $self -> {"template"} -> format_time($calendar -> {"startdate"}, "%d/%m/%Y %H:%M"),
                                                                                               "***endfmt***"      => $self -> {"template"} -> format_time($calendar -> {"enddate"}  , "%d/%m/%Y %H:%M"),
                                                                                               "***id***"          => $calendar -> {"id"}});
        }

        $content = $self -> {"template"} -> load_template("profile/calendars/caltable.tem", {"***callist***" => $callist});
    } else {
        $content = $self -> {"template"} -> load_template("profile/calendars/token_req.tem", {"***tokenurl***" => $self -> {"system"} -> {"calendar"} -> get_auth_url()});
    }

    return ($self -> {"template"} -> replace_langvar("PROFILE_CALENDARS_TITLE"),
            $self -> {"template"} -> load_template("profile/calendars/content.tem", {"***content***" => $content }),
            $self -> {"template"} -> load_template("profile/calendars/extrahead.tem"));
}


## @method $ page_display()
# Produce the string containing this block's full page content.
#
# @return The string containing this block's page content.
sub page_display {
    my $self = shift;
    my ($title, $content, $extrahead);

    my $error = $self -> check_login();
    return $error if($error);

    # Exit with a permission error unless the user has permission to compose
    if(!$self -> check_permission("profile")) {
        $self -> log("error:profile:permission", "User does not have permission to manage their profile");

        my $userbar = $self -> {"module"} -> load_module("Events::Userbar");
        my $message = $self -> {"template"} -> message_box("{L_PERMISSION_FAILED_TITLE}",
                                                           "error",
                                                           "{L_PERMISSION_FAILED_SUMMARY}",
                                                           "{L_PERMISSION_COMPOSE_DESC}",
                                                           undef,
                                                           "errorcore",
                                                           [ {"message" => $self -> {"template"} -> replace_langvar("SITE_CONTINUE"),
                                                              "colour"  => "blue",
                                                              "action"  => "location.href='".$self -> build_url(block => "", pathinfo => [])."'"} ]);

        return $self -> {"template"} -> load_template("error/general.tem",
                                                      {"***title***"     => "{L_PERMISSION_FAILED_TITLE}",
                                                       "***message***"   => $message,
                                                       "***extrahead***" => "",
                                                       "***userbar***"   => $userbar -> block_display("{L_PERMISSION_FAILED_TITLE}"),
                                                      })
    }

    # Is this an API call, or a normal page operation?
    my $apiop = $self -> is_api_operation();
    if(defined($apiop)) {
        # API call - dispatch to appropriate handler.
        given($apiop) {
            default {
                return $self -> api_html_response($self -> api_errorhash('bad_op',
                                                                         $self -> {"template"} -> replace_langvar("API_BAD_OP")))
            }
        }
    } else {
        my @pathinfo = $self -> {"cgi"} -> param('pathinfo');
        # Normal page operation.
        # ... handle operations here...

        if(!scalar(@pathinfo)) {
            ($title, $content, $extrahead) = $self -> _generate_profile();
        } else {
            given($pathinfo[0]) {
                when("import")   { ($title, $content, $extrahead) = $self -> _generate_import(); }
                default {
                    ($title, $content, $extrahead) = $self -> _generate_profile();
                }
            }
        }

        $extrahead .= $self -> {"template"} -> load_template("profile/extrahead.tem");
        return $self -> generate_events_page($title, $content, $extrahead, "compose");
    }
}

1;
