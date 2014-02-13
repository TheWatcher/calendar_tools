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


## @method get_events($calendar, $from, $days, $ids)
# Generate a hash containing events pulled from calendars with the specified ids
# from the given start date for a number of days.
#
# @param calendar A reference to a Google::Calendar object to fetch events through.
# @param from     The date to start fetching events from. Can either be a datestamp
#                 or an offset in days from the current day, or a day of the week.
#                 See Google::Calendar::request_events() for more information.
# @param days     The number of days of events to fetch.
# @param ids      A string containing the google calendar IDs to read events from.
#                 can either be a single ID string, or a comma separated list of
#                 calendar IDs.
# @return A reference to a hash containing the events, start, and end dates on
#         success. Dies on error.
sub get_events {
    my $calendar = shift;
    my $from     = shift;
    my $days     = shift;
    my $ids      = shift;

    my @idlist = split(/,/, $ids);

    my $allevents = {};
    foreach my $id (@idlist) {
        my $events = $calendar -> request_events_as_days($id, $days, $from)
            or die "Unable to read events for calendar $id: ".$calendar -> errstr()."\n";

        $calendar -> merge_day_events($allevents, $events);
    }

    return $allevents;
}


# =============================================================================
#  Event handling code

## @fn $ events_to_string($events, $title, $template, $mode)
# Convert a hash of events into a string suitable to send via email. This goes
# through the events in the events hash, using the template engine to convert
# them to human-readable strings.
#
# @param events   A reference to a hash of events as generated by Google::Calendar::request_events_as_days()
# @param title    The calendar title
# @param template A reference to a Webperl::Template object
# @param mode     The output mode, should be one of 'html' or 'text'
# @return A string containing the events in human-readable form.
sub events_to_string {
    my $events   = shift;
    my $title    = shift;
    my $template = shift;
    my $mode     = shift;
    my $ongoing  = "";
    my $upcoming = "";
    my $tableon  = "";
    my $tableup  = "";

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

            $tableon  .= $template -> load_template("$mode/table-day.tem", {"***id***"  => $day,
                                                                            "***day***" => $events -> {"days"} -> {$day} -> {"name"} -> {"short"}});
        } else {
            $upcoming .= $template -> load_template("$mode/day.tem", {"***name***"   => $events -> {"days"} -> {$day} -> {"name"} -> {"long"},
                                                                      "***id***"     => $day,
                                                                      "***events***" => $dayevents});

            $tableup  .= $template -> load_template("$mode/table-day.tem", {"***id***"  => $day,
                                                                            "***day***" => $events -> {"days"} -> {$day} -> {"name"} -> {"short"}});
        }

    }

    # Wrap the upcoming and ongoing lists as needed
    $tableon = $template -> load_template("$mode/table-ongoing.tem", {"***ongoing***" => $tableon})
        if($tableon);

    $tableup = $template -> load_template("$mode/table-upcoming.tem", {"***upcoming***" => $tableup})
        if($tableup);

    $ongoing = $template -> load_template("$mode/ongoing.tem", {"***ongoing***" => $ongoing})
        if($ongoing);

    $upcoming = $template -> load_template("$mode/upcoming.tem", {"***upcoming***" => $upcoming})
        if($upcoming);

    my $table = $template -> load_template("$mode/table.tem", {"***ongoing***"  => $tableon,
                                                               "***upcoming***" => $tableup});

    return $template -> load_template("$mode/email.tem", {"***table***"    => $table,
                                                          "***ongoing***"  => $ongoing,
                                                          "***upcoming***" => $upcoming,
                                                          "***title***"    => $title,
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


## @fn $ make_email_subject($events, $title, $template)
# Generate the subject line for the email, using the start and end dates in the
# events hash.
#
# @param events   A reference to a hash of events as generated by Google::Calendar::request_events_as_days()
# @param title    The calendar title
# @param template A reference to a Webperl::Template object
# @return A string containing the email subject.
sub make_email_subject {
    my $events   = shift;
    my $title    = shift;
    my $template = shift;

    return $template -> load_template("subject.tem", {"***start***" => $events -> {"start"},
                                                      "***end***"   => $events -> {"end"},
                                                      "***title***" => $title});
}


## @fn void generate_email($events, $title, $template, $emailer, $to, $from, $replyto)
# Send a HTML email to the specified recipient containing the events in the provided
# events hash.
#
# @param events   A reference to a hash of events as generated by Google::Calendar::request_events_as_days()
# @param title    The calendar title
# @param template A reference to a Webperl::Template object
# @param emailer  A reference to an Emailer object to send messages through.
# @param to       The email address of the recipient.
# @param from     The email address of the sender.
# @param replyto  The email address replies should be sent to.
sub generate_email {
    my $events   = shift;
    my $title    = shift;
    my $template = shift;
    my $emailer  = shift;
    my $to       = shift;
    my $from     = shift;
    my $replyto  = shift;

    my $header = [ "To"       => $to,
                   "From"     => $from,
                   "Subject"  => Encode::encode("iso-8859-1", make_email_subject($events, $title, $template)),
                   "Reply-To" => $replyto,
                 ];

    my $htmlbody = Encode::encode("iso-8859-1", events_to_string($events, $title, $template, 'html'));
    my $textbody = Encode::encode("iso-8859-1", events_to_string($events, $title, $template, 'text'));

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

foreach my $section (keys %{$config}) {
    # Only interested in calendar sections
    next unless($section =~ /^calendar.\d+$/);

    my $day_events = get_events($calendar,
                                $config -> {"notify"} -> {"from"},
                                $config -> {"notify"} -> {"days"},
                                $config -> {$section} -> {"id"});

    generate_email($day_events,
                   $config -> {$section} -> {"title"},
                   $template, $emailer,
                   $config -> {$section} -> {"to"},
                   $config -> {$section} -> {"from"},
                   $config -> {$section} -> {"replto"});
}