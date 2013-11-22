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
use Webperl::Template;
use DateTime;
use HTML::WikiConverter;
use LWP::Authen::OAuth2;
use Data::Dumper;

use lib path_join($scriptpath, "modules");
use Emailer;
use Google::Calendar;

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


sub events_to_string {
    my $events   = shift;
    my $template = shift;
    my $mode     = shift;
    my $ongoing  = "";
    my $upcoming = "";
    my $table    = "";

    foreach my $day (sort keys(%{$events -> {"days"}})) {
        my $dayevents = "";

        foreach my $event (@{$events -> {"days"} -> {$day} -> {"events"}}) {
            $dayevents .= $template -> load_template("$mode/event.tem", {"***summary***"  => $event -> {"summary"},
                                                                         "***url***"      => $event -> {"htmlLink"},
                                                                         "***time***"     => $event -> {"timestring"},
                                                                         "***location***" => $event -> {"location"} });
        }

        if(DateTime->compare($events -> {"days"} -> {$day} -> {"date"}, $events -> {"startdate"}) < 0) {
            $ongoing .= $template -> load_template("$mode/day.tem", {"***name***"   => $events -> {"days"} -> {$day} -> {"name"} -> {"long"},
                                                                     "***id***"     => $day,
                                                                     "***events***" => $dayevents});
        } else {
            $upcoming .= $template -> load_template("$mode/day.tem", {"***name***"   => $events -> {"days"} -> {$day} -> {"name"} -> {"long"},
                                                                      "***id***"     => $day,
                                                                      "***events***" => $dayevents});
        }

        $table  .= $template -> load_template("$mode/table-day.tem", {"***id***"  => $day,
                                                                      "***day***" => $events -> {"days"} -> {$day} -> {"name"} -> {"short"}});
    }

    $table = $template -> load_template("$mode/table.tem", {"***days***" => $table});

    return $template -> load_template("$mode/email.tem", {"***table***"    => $table,
                                                          "***ongoing***"  => $ongoing,
                                                          "***upcoming***" => $upcoming,
                                                          "***start***"    => $events -> {"start"},
                                                          "***end***"      => $events -> {"end"}});
}


# =============================================================================
#  Email related

## @method $ html_to_markdown($html)
# Convert the specified html into markdown text.
#
# @param html The HTML to convert to markdown.
# @return The markdown version of the text.
sub html_to_markdown {
    my $html      = shift;
    my $entitymap = { '&ndash;'  => '-',
                      '&mdash;'  => '-',
                      '&rsquo;'  => "'",
                      '&lsquo;'  => "'",
                      '&ldquo;'  => '"',
                      '&rdquo;'  => '"',
                      '&hellip;' => '...',
                      '&gt;'     => '>',
                      '&lt;'     => '<',
                      '&amp;'    => '&',
                      '&nbsp;'   => ' ',
    };

    # Handle html entities that are going to break...
    foreach my $entity (keys(%{$entitymap})) {
        $html =~ s/$entity/$entitymap->{$entity}/g;
    }

    my $converter = new HTML::WikiConverter(dialect => 'Markdown',
                                            link_style => 'inline',
                                            image_tag_fallback => 0);
    my $body = $converter -> html2wiki($html);

    # Clean up html the converter misses consistently
    $body =~ s|<br\s*/>|\n|g;
    $body =~ s|&gt;|>|g;

    return $body
}


sub make_email_subject {
    my $events   = shift;
    my $template = shift;

    return $template -> load_template("subject.tem", {"***start***" => $events -> {"start"},
                                                      "***end***"   => $events -> {"end"}});
}


sub generate_email {
    my $events   = shift;
    my $template = shift;
    my $emailer  = shift;
    my $settings = shift;

    my $header = [ "To"       => $settings -> {"email"} -> {"to"},
                   "From"     => $settings -> {"email"} -> {"from"},
                   "Subject"  => Encode::encode("iso-8859-1", make_email_subject($events, $template)),
                   "Reply-To" => $settings -> {"email"} -> {"replyto"},
                 ];

    my $htmlbody = Encode::encode("iso-8859-1", events_to_string($events, $template, 'html'));
    my $textbody = Encode::encode("iso-8859-1", events_to_string($events, $template, 'text'));

    $emailer -> send_email({ header => $header,
                             html_body => $htmlbody,
                             text_body => $textbody})
        or die "Email failed: ".$emailer -> errstr();
}


$config = Webperl::ConfigMicro -> new(path_join($scriptpath, "config", "config.cfg"), quote_values => '')
    or die "Unable to load configuration: ".$Webperl::SystemModule::errstr;

$config -> {"config"} -> {"base"} = $scriptpath;

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

my $template = Webperl::Template -> new(settings => $config)
    or die "Unable to create template object\n";

my $emailer = Emailer -> new(host => $config -> {"email"} -> {"host"},
                             port => $config -> {"email"} -> {"port"})
    or die "Unable to create emailer object\n";

my $day_events = $calendar -> request_events_as_days($config -> {"notify"} -> {"days"}, $config -> {"notify"} -> {"from"});
generate_email($day_events, $template, $emailer, $config);
