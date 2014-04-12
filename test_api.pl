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
use Webperl::Utils qw(path_join save_file);
use Webperl::Template;
use DateTime;
use DBI;
use HTML::WikiConverter;
use LWP::Authen::OAuth2;
use Data::Dumper;

use lib path_join($scriptpath, "modules");
use Emailer;
use Google::Calendar;

# =============================================================================
#  Google interaction code

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


$config = Webperl::ConfigMicro -> new(path_join($scriptpath, "config", "site.cfg"), quote_values => '')
    or die "Unable to load configuration: ".$Webperl::SystemModule::errstr;

$config -> {"config"} -> {"base"} = $scriptpath;

my $dbh = DBI->connect($config -> {"database"} -> {"database"},
                       $config -> {"database"} -> {"username"},
                       $config -> {"database"} -> {"password"},
                       { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1 })
    or die "Unable to connect to database: ".$DBI::errstr."\n";

# Pull configuration data out of the database into the settings hash
$config -> load_db_config($dbh, $config -> {"database"} -> {"settings"});

my $agent = LWP::Authen::OAuth2->new(client_id        => $config -> {"config"} -> {"google:client_id"},
                                     client_secret    => $config -> {"config"} -> {"google:client_secret"},
                                     service_provider => "Google",
                                     redirect_uri     => $config -> {"config"} -> {"google:redirect_uri"},

                                     # Optional hook, but recommended.
                                     save_tokens      => \&save_tokens,
                                     save_tokens_args => [ $dbh, $config ],

                                     # This is for when you have tokens from last time.
                                     token_string     => $config -> {"config"} -> {"google:token"},
                                     scope            => $config -> {"config"} -> {"google:scope"},

                                     flow => "web server",
                 );

my $calendar = Google::Calendar -> new(agent    => $agent,
                                       settings => $config)
    or die "Unable to create calendar object\n";

my $template = Webperl::Template -> new(settings => $config)
    or die "Unable to create template object\n";

my $resp = $calendar -> calendar_info("thisisnotacalendarid");
print "Resp: ".($resp ? Dumper($resp) : $calendar -> errstr());
