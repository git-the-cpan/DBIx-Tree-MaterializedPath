package DBIx::Tree::MaterializedPath;
use base DBIx::Tree::MaterializedPath::Node;

use warnings;
use strict;

use Carp;

=head1 NAME

DBIx::Tree::MaterializedPath - fast DBI queries and updates on "materialized path" trees

=head1 VERSION

Version 0.06

=cut

use version 0.74; our $VERSION = qv('0.06');

=head1 SYNOPSIS

    use DBIx::Tree::MaterializedPath;

    my $root = DBIx::Tree::MaterializedPath->new({
                                  dbh        => $dbh,
                                  table_name => 'my_movies_tree',
                                 });

    # Add children to a node (assumes there is a "name" column
    # in the "my_movies_tree" table):
    #
    my @children = $root->add_children([
                                        {name => 'Drama'},
                                        {name => 'Sci-Fi'},
                                        {name => 'Horror'},
                                       ]);

    # Add a new child in front of any existing children,
    # instead of at the end of the list:
    #
    my $child = $root->add_children_at_left([{name => 'Comedy'}]);

    # Locate a node (uses SQL::Abstract to query node metadata):
    #
    my $sci_fi_node = $root->find(where => {name => {-like => 'Sci%'}});

    $sci_fi_node->add_child({name => 'The Andromeda Strain'});

    # Get children of a node:
    #
    @children = $sci_fi_node->get_children();

    # Access arbitrary node metadata:
    #
    print $children[0]->data->{name};    # 'The Andromeda Strain'

    # Walk tree (or node) descendants and operate on each node:
    #
    my $descendants = $tree->get_descendants;
    $descendants->traverse($coderef);

=head1 DESCRIPTION

This module implements database storage for a "materialized path"
parent/child tree.

Most methods (other than C<new()>) can act on any node in the tree,
including the root node.  For documentation on additional methods
see
L<DBIx::Tree::MaterializedPath::Node|DBIx::Tree::MaterializedPath::Node>.

=head2 BACKGROUND

This distribution was inspired by Dan Collis-Puro's
L<DBIx::Tree::NestedSet|DBIx::Tree::NestedSet> modules
but is implemented in a more object-oriented way.

Nested set trees are fast for typical tree queries (e.g. getting
a node's parents, children or siblings), because those operations
can typically be done with a single SQL statement.  However, nested
set trees are generally slow for modifications to the tree
structure (e.g. adding, moving or deleting a node), because those
operations typically require renumbering the hierarchy info for
many affected nodes (often every node) due to a single
modification.  (This may not be an issue for you if you have data
that is read often and updated very infrequently.)

This materialized path tree implementation does away with the
integer "left" and "right" values that are stored with each node by
nested-set trees, and instead uses a formatted representation of
the path to the node (the "materialized path"), which is stored as
a text string.  It retains the speed for tree query operations,
which can still typically be done with a single SQL statement, but
generally requires far fewer updates to existing rows when
modifications are made to the tree.  This makes it better suited to
situations where the tree is updated with any frequency.

=head1 METHODS

=head2 new

    my $root = DBIx::Tree::MaterializedPath->new( $options_hashref )

C<new()> initializes and returns a node pointing to the root of your
tree.

B<Note:>  C<new()> assumes that the database table containing the
tree data already exists, it does not create the table for you.
The table may be empty or may contain previously populated tree data.
In addition to the required columns described below, the table may
contain as many other columns as needed to store the metadata that
corresponds to each node.

If the tree table does not contain a row with a path corresponding to
the root node, a row for the root node will be inserted into the
table.  The new row will contain no metadata, so your application
would need to call
L<data()|DBIx::Tree::MaterializedPath::Node/data>
to add any required metadata.

C<new()> accepts a hashref of arguments:

=over 4

=item B<dbh>

B<Required.>

An active DBI handle as returned by C<DBI::connect()>.

=item B<table_name>

Optional, defaults to "B<my_tree>".

The name of the database table that contains the tree data.

=item B<id_column_name>

Optional, defaults to "B<id>".

The name of the database column that contains the unique ID
for the node.

The ID is used internally as a "handle" to the row in the
database corresponding to each node.  (This column would typically
be created in the database as e.g. a "sequence" or "serial" or
"autoincrement" type.)

=item B<path_column_name>

Optional, defaults to "B<path>".

The name of the database column that contains the representation
of the path from the root of the tree to the node.

Note that the path values which get stored in this column are
generated by the code, and may not be particularly human-readable.

=item B<auto_create_root>

Optional, defaults to B<true>.

If true, and no existing row is found in the database which matches
the root node's path, will create a new row for the root node.

If false, and no existing row is found in the database which matches
the root node's path, will croak.

Note that if a new root node row is created, it will not contain any
values in any metadata fields.  This means the database insert will
fail if any of the corresponding columns in the database are required
to be non-NULL.

=back

=cut

sub new
{
    my ($class, @args) = @_;

    my $options = ref $args[0] eq 'HASH' ? $args[0] : {@args};

    my $self = bless {}, ref($class) || $class;

    $self->{_root}    = $self;
    $self->{_is_root} = 1;

    $self->SUPER::_init($options);
    $self->_init($options);

    return $self;
}

sub _init
{
    my ($self, $options) = @_;

    $self->{_dbh}              = $options->{dbh};
    $self->{_table_name}       = $options->{table_name} || 'my_tree';
    $self->{_id_column_name}   = $options->{id_column_name} || 'id';
    $self->{_path_column_name} = $options->{path_column_name} || 'path';

    $self->{_pathmapper} = $options->{path_mapper}
      || DBIx::Tree::MaterializedPath::PathMapper->new();

    $self->{_auto_create_root} =
      exists $options->{auto_create_root} ? $options->{auto_create_root} : 1;

    $self->{_sqlmaker}  = SQL::Abstract->new();
    $self->{_sth_cache} = {};

    my $dbh = $self->{_dbh};
    croak 'Missing required parameter: dbh' unless $dbh;
    croak 'Invalid dbh: not a "DBI::db"' unless ref($dbh) eq 'DBI::db';

    local $dbh->{PrintError} = 0;    ## no critic (Variables::ProhibitLocalVars)
    local $dbh->{PrintWarn}  = 0;    ## no critic (Variables::ProhibitLocalVars)
    local $dbh->{RaiseError} = 1;    ## no critic (Variables::ProhibitLocalVars)

    # Make sure the tree table exists in the database:
    my $table = $self->{_table_name};
    eval { $dbh->do("select count(*) from $table limit 1"); 1; }
      or do { croak qq{Table "$table" does not exist}; };

    # Make sure the column exists in the tree table:
    my $id_col = $self->{_id_column_name};
    eval { $dbh->do("select $id_col from $table limit 1"); 1; }
      or do { croak qq{Column "$id_col" does not exist}; };

    # Make sure the column exists in the tree table:
    my $path_col = $self->{_path_column_name};
    eval { $dbh->do("select $path_col from $table limit 1"); 1; }
      or do { croak qq{Column "$path_col" does not exist}; };

    # Check if DB is capable of transactions:
    #
    # If RaiseError is false, begin_work() will:
    #     return true if a new transaction was started
    #     return false if already in a transaction
    #     croak if transactions not supported
    #
    my $started_a_new_transaction = 0;
    eval {
        ## no critic (Variables::ProhibitLocalVars)
        local $dbh->{RaiseError} = 0;
        ## use critic
        $started_a_new_transaction = $dbh->begin_work;
        $self->{_can_do_transactions} = 1;
        1;
    } or do { $self->{_can_do_transactions} = 0; };

    ## no critic (ErrorHandling::RequireCheckingReturnValueOfEval)
    eval { $dbh->rollback } if $started_a_new_transaction;
    ## use critic

    # Load the root node:
    my $root_node_path = $self->_map_path('1');
    eval { $self->_load_from_db_using_path($root_node_path); 1; } or do
    {
        croak $@ unless $@ =~ /No\s+row/msx;
        croak $@ unless $self->{_auto_create_root};

        # If we got here, the root node was not found and
        # auto_create_root is true, so create the node
        $self->_insert_into_db_from_hashref({$path_col => $root_node_path});
    };

    return;
}

=head2 clone

Create a clone of an existing tree object.

=cut

use Clone ();

sub clone
{
    my ($self) = @_;

    my $clone = Clone::clone($self);

    # Fix up database handles that Clone::clone() might have broken:
    $clone->{_dbh}       = $self->{_dbh};
    $clone->{_sth_cache} = $self->{_sth_cache};

    return $clone;
}

###################################################################

#
# Execute code (within a transaction if the database supports
# transactions).
#
sub _do_transaction
{
    my ($self, $code, @args) = @_;

    unless ($self->{_can_do_transactions})
    {
        $code->(@args);
        return;
    }

    my $dbh = $self->{_dbh};
    local $dbh->{PrintError} = 0;    ## no critic (Variables::ProhibitLocalVars)
    local $dbh->{PrintWarn}  = 0;    ## no critic (Variables::ProhibitLocalVars)
    local $dbh->{RaiseError} = 1;    ## no critic (Variables::ProhibitLocalVars)

    # If RaiseError is true, begin_work() will:
    #     return true if a new transaction was started
    #     croak if already in a transaction
    #     croak if transactions not supported
    #
    my $started_a_new_transaction = 0;
    eval { $started_a_new_transaction = $dbh->begin_work } or do { };

    eval {
        $code->(@args);
        $dbh->commit if $started_a_new_transaction;
        1;
      } or do
    {
        my $msg = $@;
        ## no critic (ErrorHandling::RequireCheckingReturnValueOfEval)
        eval { $dbh->rollback } if $started_a_new_transaction;
        ## use critic
        croak $msg;
    };

    return;
}

###################################################################

#
# Manage a cache of active statement handles:
#

sub _cached_sth
{
    my ($self, $sql) = @_;

    $self->{_sth_cache}->{$sql} ||= $self->_create_sth($sql);

    return $self->{_sth_cache}->{$sql};
}

# Setting DBI's "STH_CACHE_REPLACE => 3" will:
#   1) Suppress DBI warnings from prepare_cached() if SQL matching
#      an existing active handle is supplied, and
#   2) Replace the existing handle in the DBI cache with the
#      newly-generated one
#
use Readonly;
Readonly::Scalar my $STH_CACHE_REPLACE => 3;

sub _create_sth
{
    my ($self, $sql) = @_;

    my $dbh = $self->{_dbh};

    local $dbh->{PrintError} = 0;    ## no critic (Variables::ProhibitLocalVars)
    local $dbh->{PrintWarn}  = 0;    ## no critic (Variables::ProhibitLocalVars)
    local $dbh->{RaiseError} = 1;    ## no critic (Variables::ProhibitLocalVars)

    my $sth = $dbh->prepare_cached($sql, undef, $STH_CACHE_REPLACE);

    return $sth;
}

###################################################################

#
# Manage a cache of generated SQL:
#

sub _cached_sql
{
    my ($self, $sql_key, $args) = @_;

    my $sql = $self->{_sql}->{$sql_key};
    unless ($sql)
    {
        my $func =
          ($sql_key =~ /^VALIDATE_/msx)
          ? '_cached_sql_VALIDATE'
          : "_cached_sql_$sql_key";
        $sql = $self->$func($args);
        $self->{_sql}->{$sql_key} = $sql;
    }
    return $sql;
}

sub _cached_sql_SELECT_STAR_FROM_TABLE_WHERE_ID_EQ_X_LIMIT_1
{
    my $self   = shift;
    my $table  = $self->{_table_name};
    my $id_col = $self->{_id_column_name};
    my $sql    = "SELECT * FROM $table WHERE ( $id_col = ? ) LIMIT 1";
    return $sql;
}

sub _cached_sql_SELECT_STAR_FROM_TABLE_WHERE_PATH_EQ_X_LIMIT_1
{
    my $self     = shift;
    my $table    = $self->{_table_name};
    my $path_col = $self->{_path_column_name};
    my $sql      = "SELECT * FROM $table WHERE ( $path_col = ? ) LIMIT 1";
    return $sql;
}

sub _cached_sql_SELECT_ID_FROM_TABLE_WHERE_PATH_EQ_X_LIMIT_1
{
    my $self     = shift;
    my $table    = $self->{_table_name};
    my $id_col   = $self->{_id_column_name};
    my $path_col = $self->{_path_column_name};
    my $sql      = "SELECT $id_col FROM $table WHERE ( $path_col = ? ) LIMIT 1";
    return $sql;
}

sub _cached_sql_UPDATE_TABLE_SET_PATH_EQ_X_WHERE_ID_EQ_X
{
    my $self     = shift;
    my $table    = $self->{_table_name};
    my $path_col = $self->{_path_column_name};
    my $id_col   = $self->{_id_column_name};
    my $sql      = "UPDATE $table SET $path_col = ? WHERE ( $id_col = ? )";
    return $sql;
}

sub _cached_sql_VALIDATE
{
    my $self     = shift;
    my $columns  = shift;
    my $table    = $self->{_table_name};
    my $id_col   = $self->{_id_column_name};
    my $where    = {$id_col => 0};
    my $sqlmaker = $self->{_sqlmaker};
    my $sql      = $sqlmaker->select($table, $columns, $where);
    $sql .= ' LIMIT 1';
    return $sql;
}

###################################################################

1;

__END__

=head1 SEE ALSO

L<DBIx::Tree::MaterializedPath::Node|DBIx::Tree::MaterializedPath::Node>

L<DBIx::Tree::MaterializedPath::PathMapper|DBIx::Tree::MaterializedPath::PathMapper>

Dan Collis-Puro's L<DBIx::Tree::NestedSet|DBIx::Tree::NestedSet>

An article about implementing materialized path and nested set trees:
L<http://www.dbazine.com/oracle/or-articles/tropashko4>

An article about implementing nested set and static hierarchy trees:
L<http://grzm.com/fornow/archives/2004/07/10/static_hierarchies>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-dbix-tree-materializedpath at rt.cpan.org>,
or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=DBIx-Tree-MaterializedPath>.
I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc DBIx::Tree::MaterializedPath

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=DBIx-Tree-MaterializedPath>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/DBIx-Tree-MaterializedPath>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/DBIx-Tree-MaterializedPath>

=item * Search CPAN

L<http://search.cpan.org/dist/DBIx-Tree-MaterializedPath>

=back

=head1 AUTHOR

Larry Leszczynski, C<< <larryl at cpan.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2008 Larry Leszczynski, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

