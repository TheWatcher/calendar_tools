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
use Google::Calendar;
use LWP::Authen::OAuth2;
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


# =============================================================================
#  Event handling code


# FIXME: needs to generate a html block
# FIXME: make <a href="calendar link" target="_blank">summary</a>
sub generate_days {
    my $days = shift;

    foreach my $day (sort keys(%{$days})) {
        print $days -> {$day} -> {"name"}."\n".("-" x length($days -> {$day} -> {"name"}))."\n";

        foreach my $event (@{$days -> {$day} -> {"events"}}) {
            print $event -> {"summary"}."\n";
            print "\t".$event -> {"timestring"}."\n";
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

my $calendar = Google::Calendar -> new(agent    => $agent,
                                       settings => $config)
    or die "Unable to create calendar object\n";

my $day_events = $calendar -> request_events_as_days($config -> {"notify"} -> {"days"}, $config -> {"notify"} -> {"from"});
generate_days($day_events);

# FIXME: send html email here
