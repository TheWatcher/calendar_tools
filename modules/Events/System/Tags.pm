## @file
# This file contains the implementation of the tag handling engine.
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
# This class encapsulates operations involving tags in the system.
package Events::System::Tags;

use strict;
use base qw(Webperl::SystemModule);

# ==============================================================================
#  Creation

## @cmethod $ new(%args)
# Create a new Tags object to manage tag allocation and lookup.
# The minimum values you need to provide are:
#
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object
# * logger    - The system logger object.
#
# @param args A hash of key value pairs to initialise the object with.
# @return A new Tags object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    return $self;
}


# ============================================================================
#  Public interface - tag creation, deletion, etc

## @method $ create($name, $userid)
# Create a new tag with the specified name. This will create a new tag, setting
# its name and creator to the values specified. Note that this will not check
# whether a tag with the same name already exists
#
# @param name   The name of the tag to add.
# @param userid The ID of the user creating the tag.
# @return The new tag ID on success, undef on error.
sub create {
    my $self   = shift;
    my $name   = shift;
    my $userid = shift;

    $self -> clear_error();

    my $newh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"tags"}."
                                            (name, creator_id, created)
                                            VALUES(?, ?, UNIX_TIMESTAMP())");
    my $rows = $newh -> execute($name, $userid);
    return $self -> self_error("Unable to perform tag insert: ". $self -> {"dbh"} -> errstr) if(!$rows);
    return $self -> self_error("Tag insert failed, no rows inserted") if($rows eq "0E0");

    # FIXME: This ties to MySQL, but is more reliable that last_insert_id in general.
    #        Try to find a decent solution for this mess...
    # NOTE: the DBD::mysql documentation doesn't actually provide any useful information
    #       about what this will contain if the insert fails. In fact, DBD::mysql calls
    #       libmysql's mysql_insert_id(), which returns 0 on error (last insert failed).
    #       There, why couldn't they bloody /say/ that?!
    my $tagid = $self -> {"dbh"} -> {"mysql_insertid"};
    return $self -> self_error("Unable to obtain id for tag '$name'") if(!$tagid);

    return $tagid;
}


## @method $ destroy($tagid)
# Attempt to remove the specified tag, and any assignments of it, from the system.
#
# @warning This will remove the tag, any tag assignments, and any active flags for the
#          tag. It will work even if there are resources currently tagged with this tag.
#          Use with extreme caution!
#
# @param tagid The ID of the tag to remove from the system
# @return true on success, undef on error
sub destroy {
    my $self  = shift;
    my $tagid = shift;

    $self -> clear_error();

    # Delete any tag assignments first. This is utterly indiscriminate, if this breaks
    # something important, don't say I didn't warn you.
    my $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"event_tags"}."
                                             WHERE tag_id = ?");
    $nukeh -> execute($tagid)
        or return $self -> self_error("Unable to perform tag allocation removal: ". $self -> {"dbh"} -> errstr);

    # And now delete the tag itself
    $nukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"tags"}."
                                          WHERE id = ?");
    $nukeh -> execute($tagid)
        or return $self -> self_error("Unable to perform tag removal: ". $self -> {"dbh"} -> errstr);

    return 1;
}


## @method $ get_tagid($name, $userid)
# Obtain the ID associated with the specified tag. If the tag does not yet exist
# in the tags table, this will create it and return the ID the new row was
# allocated.
#
# @param name   The name of the tag to obtain the ID for
# @param userid The ID of the user requesting the tag, in case it must be created.
# @return The ID of the tag on success, undef on error.
sub get_tagid {
    my $self   = shift;
    my $name   = shift;
    my $userid = shift;

    # Search for a tag with the specified name, give up if an error occurred
    my $tagid = $self -> _fetch_tagid($name);
    return $tagid if($tagid || $self -> {"errstr"});

    # Get here and the tag doesn't exist, create it
    return $self -> create($name, $userid);
}


# ============================================================================
#  Private functions


## @method private $ _fetch_tagid($name)
# Given a tag name, attempt to find a tag record for that name. This will locate the
# first defined tag whose name matches the provided name. Note that if there are
# duplicate tags in the system, this will never find duplicates - it is guaranteed to
# find the tag with the lowest ID whose name matches the provided value, or nothing.
#
# @param name The name of the tag to find.
# @return The ID of the tag with the specified name on success, undef if the tag
#         does not exist or an error occurred.
sub _fetch_tagid {
    my $self = shift;
    my $name = shift;

    $self -> clear_error();

    # Does the tag already exist
    my $tagid  = $self -> {"dbh"} -> prepare("SELECT id FROM ".$self -> {"settings"} -> {"database"} -> {"tags"}."
                                              WHERE name LIKE ?");
    $tagid -> execute($name)
        or return $self -> self_error("Unable to perform tag lookup: ".$self -> {"dbh"} -> errstr);
    my $tagrow = $tagid -> fetchrow_arrayref();

    # Return the ID if found, undef otherwise
    return $tagrow ? $tagrow -> [0] : undef;;
}

1;
