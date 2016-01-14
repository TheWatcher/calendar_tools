## @file
# This file contains the implementation of the CalSearch user toolbar.
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

## @class CalSearch::Userbar
# The Userbar class encapsulates the code required to generate and
# manage the user toolbar.
package CalSearch::Userbar;

use strict;
use base qw(CalSearch);
use v5.12;


# ==============================================================================
#  Bar generation

## @method $ block_display($title, $current, $doclink)
# Generate a user toolbar, populating it as needed to reflect the user's options
# at the current time.
#
# @param title   A string to show as the page title.
# @param current The current page name.
# @param doclink The name of a document link to include in the userbar. If not
#                supplied, no link is shown.
# @return A string containing the user toolbar html on success, undef on error.
sub block_display {
    my $self    = shift;
    my $title   = shift;
    my $current = shift;
    my $doclink = shift;

    $self -> clear_error();

    my $loginurl = $self -> build_url(block => "login",
                                      fullurl  => 1,
                                      pathinfo => [],
                                      params   => {},
                                      forcessl => 1);

    my $fronturl = $self -> build_url(block    => $self -> {"settings"} -> {"config"} -> {"default_block"},
                                      fullurl  => 1,
                                      pathinfo => [],
                                      params   => {});

    # Initialise fragments to sane "logged out" defaults.
    my ($import, $userprofile, $docs) =
        ($self -> {"template"} -> load_template("userbar/import_disabled.tem"),
         $self -> {"template"} -> load_template("userbar/profile_loggedout_http".($ENV{"HTTPS"} eq "on" ? "s" : "").".tem", {"***url-login***" => $loginurl}),
         $self -> {"template"} -> load_template("userbar/doclink_disabled.tem"),
        );

    # Is documentation available?
    my $url = $self -> get_documentation_url($doclink);
    $docs = $self -> {"template"} -> load_template("userbar/doclink_enabled.tem", {"***url-doclink***" => $url})
        if($url);

    # Is the user logged in?
    if(!$self -> {"session"} -> anonymous_session()) {
        my $user = $self -> {"session"} -> get_user_byid()
            or return $self -> self_error("Unable to obtain user data for logged in user. This should not happen!");

        $import  = $self -> {"template"} -> load_template("userbar/import_enabled.tem"  , {"***url-import***" => $self -> build_url(block => "profile", pathinfo => ['import'])})
            if($self -> check_permission("import") && $current ne "import");

        # User is logged in, so actually reflect their current options and state
        $userprofile = $self -> {"template"} -> load_template("userbar/profile_loggedin.tem", {"***realname***"    => $user -> {"fullname"},
                                                                                               "***username***"    => $user -> {"username"},
                                                                                               "***gravhash***"    => $user -> {"gravatar_hash"},
                                                                                               "***url-logout***"  => $self -> build_url(block => "login"  , pathinfo => ["logout"])});
    } # if(!$self -> {"session"} -> anonymous_session())

    return $self -> {"template"} -> load_template("userbar/userbar.tem", {"***pagename***"  => $title,
                                                                          "***front_url***" => $fronturl,
                                                                          "***import***"    => $import,
                                                                          "***doclink***"   => $docs,
                                                                          "***profile***"   => $userprofile});
}


## @method $ page_display()
# Produce the string containing this block's full page content. This is primarily provided for
# API operations that allow the user to change their profile and settings.
#
# @return The string containing this block's page content.
sub page_display {
    my $self = shift;
    my ($content, $extrahead, $title);

    if(!$self -> {"session"} -> anonymous_session()) {
        my $user = $self -> {"session"} -> get_user_byid()
            or return '';

        my $apiop = $self -> is_api_operation();
        if(defined($apiop)) {
            given($apiop) {
                default {
                    return $self -> api_html_response($self -> api_errorhash('bad_op',
                                                                             $self -> {"template"} -> replace_langvar("API_BAD_OP")))
                }
            }
        }
    }

    return "<p class=\"error\">".$self -> {"template"} -> replace_langvar("BLOCK_PAGE_DISPLAY")."</p>";
}

1;
