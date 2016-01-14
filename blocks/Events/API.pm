# @file
# This file contains the implementation of the API class
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
package Events::API;

use strict;
use experimental 'smartmatch';
use base qw(Events);
use v5.12;

## @method private $ _build_tokenauth_response()
# Generate a hash containing the data to send back in response to a token.auth
# API request. This API operation is triggered by google as part of the OAuth
# process - it will contain a `state` variable matching the csrf token for the
# user requesting a token, and an auth code that can be exchanged to a token.
# This function locates the user matching the state, and if one is found it
# exchanges the code for a token string for the user.
sub _build_tokenauth_response() {
    my $self = shift;



}


## @method private $ _build_tokencheck_response()
# Generate a hash contaning the data to send back in response to a token.check
# API request.
sub _build_tokencheck_response() {
    my $self = shift;

    my $token_set = $self -> {"system"} -> {"calendar"} -> user_has_token();

    return { "token" => {"set" => $token_set ? "true" : "false" } };
}


# ============================================================================
#  Interface functions

## @method $ page_display()
# Produce the string containing this block's full page content. This generates
# the compose page, including any errors or user feedback.
#
# @return The string containing this block's page content.
sub page_display {
    my $self = shift;

    # Is this an API call, or a normal page operation?
    my $apiop = $self -> is_api_operation();
    if(defined($apiop)) {
        # API call - dispatch to appropriate handler.
        given($apiop) {
            when("token.check") { return $self -> api_response($self -> _build_tokencheck_response()); }

            default {
                return $self -> api_response($self -> api_errorhash('bad_op',
                                                                    $self -> {"template"} -> replace_langvar("API_BAD_OP")))
            }
        }
    } else {
        my $userbar = $self -> {"module"} -> load_module("Events::Userbar");
        my $message = $self -> {"template"} -> message_box("{L_APIDIRECT_FAILED_TITLE}",
                                                           "error",
                                                           "{L_APIDIRECT_FAILED_SUMMARY}",
                                                           "{L_APIDIRECT_FAILED_DESC}",
                                                           undef,
                                                           "errorcore",
                                                           [ {"message" => $self -> {"template"} -> replace_langvar("SITE_CONTINUE"),
                                                              "colour"  => "blue",
                                                              "action"  => "location.href='".$self -> build_url(block => $self -> {"settings"} -> {"config"} -> {"default_block"}, pathinfo => [])."'"} ]);

        return $self -> {"template"} -> load_template("error/general.tem",
                                                      {"***title***"     => "{L_APIDIRECT_FAILED_TITLE}",
                                                       "***message***"   => $message,
                                                       "***extrahead***" => "",
                                                       "***userbar***"   => $userbar -> block_display("{L_APIDIRECT_FAILED_TITLE}"),
                                                      })
    }
}

1;
