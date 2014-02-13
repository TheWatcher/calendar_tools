## @file
# This file contains the implementation of the email sender.
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
# This class encapsulates operations involving sending email
package Emailer;

use v5.12;

use base qw(Webperl::SystemModule);
use Encode;
use Email::MIME;
use Email::MIME::CreateHTML;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use Email::Sender::Transport::SMTP::Persistent;
use Try::Tiny;

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(minimal    => 1,
                                        @_)
        or return undef;

    if($self -> {"persist"}) {
        eval { $self -> {"smtp"} = Email::Sender::Transport::SMTP::Persistent -> new($self -> _build_smtp_args()); };
        return SystemModule::set_error("SMTP Initialisation failed: $@") if($@);
    }

    return $self;
}

# =============================================================================
#  Interface

## @method $ send_email($email)
# Send the specified email to its recipients. This constructs the email from the
# header, html body, and text body provided and sends it.
#
# @param email A reference to a hash containing the email to send. Must contain
#              `header` (a reference to an array of header fields to set),
#              `html_body` (the html version of the text to send), and `text_body`
#              containing the text version.
# @return true on success, undef on error.
sub send_email {
    my $self  = shift;
    my $email = shift;

    if(!$self -> {"persist"}) {
        eval { $self -> {"smtp"} = Email::Sender::Transport::SMTP -> new($self -> _build_smtp_args()); };
        return $self -> self_error("SMTP Initialisation failed: $@") if($@);
    }

    # Eeech, HTML email ;.;
    my $outgoing = Email::MIME -> create_html(header    => $email -> {"header"},
                                              body      => $email -> {"html_body"},
                                              embed     => 0,
                                              text_body => $email -> {"text_body"});

    try {
        sendmail($outgoing, { from      => $self -> {"env_sender"},
                              transport => $self -> {"smtp"}});
    } catch {
        # ... ooor, crash into the ground painfully.
        return $self -> self_error("Delivery of email failed: $_");
    };

    return 1;
}


# ============================================================================
#  Internal support code

## @method private % _build_smtp_args()
# Build the argument hash to pass to the SMTP constructor.
#
# @return A hash of arguments to pass to the Email::Sender::Transport::SMTP constructor
sub _build_smtp_args {
    my $self = shift;

    my %args = (host => $self -> {"host"},
                port => $self -> {"port"},
                ssl  => $self -> {"ssl"} || 0);

    if($self -> {"username"} && $self -> {"password"}) {
        $args{"sasl_username"} = $self -> {"username"};
        $args{"sasl_password"} = $self -> {"password"};
    }

    return %args;
}

1;
