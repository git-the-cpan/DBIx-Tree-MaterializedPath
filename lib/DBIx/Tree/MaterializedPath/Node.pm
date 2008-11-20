package DBIx::Tree::MaterializedPath::Node;

use warnings;
use strict;

use Carp;
use SQL::Abstract;
use Scalar::Util qw(blessed);

use DBIx::Tree::MaterializedPath::PathMapper;

=head1 NAME

DBIx::Tree::MaterializedPath::Node - node objects for "materialized path" trees

=head1 VERSION

Version 0.01

=cut

use version 0.74; our $VERSION = qv('0.01');

=head1 SYNOPSIS

This module implements nodes for a "materialized path"
parent/child tree.

=head1 METHODS

=head2 new

    my $node = DBIx::Tree::MaterializedPath::Node->new( $root );

C<new()> initializes a node in the tree.

B<Note:> Normally nodes would not be created independently - create
a tree first using
L<DBIx::Tree::MaterializedPath|DBIx::Tree::MaterializedPath>
and then create/manipulate its children.

C<new()> expects a single argument, which must be a
L<DBIx::Tree::MaterializedPath|DBIx::Tree::MaterializedPath>
object representing the root of the tree that this node belongs to.

=cut

sub new
{
    my $class = shift;

    my $root = shift;
    croak 'Missing tree root' unless $root;
    croak 'Invalid tree root: is not a "DBIx::Tree::MaterializedPath"'
      unless blessed($root) && $root->isa('DBIx::Tree::MaterializedPath');

    my $options = ref $_[0] eq 'HASH' ? shift : {@_};

    my $self = bless {}, ref($class) || $class;

    $self->{_root}    = $root;
    $self->{_is_root} = 0;

    $self->_init($options);
    return $self;
}

sub _init
{
    my ($self, $options) = @_;

    $self->{_deleted}  = 0;
    $self->{_node_sql} = {};
}

=head2 is_root

Returns true if this node is the root of the tree

=cut

sub is_root
{
    my ($self) = @_;
    return $self->{_is_root};
}

=head2 get_root

Returns root of the tree

=cut

sub get_root
{
    my ($self) = @_;
    return $self->{_root};
}

=head2 is_same_node_as

    $node->is_same_node_as( $other_node )

Returns true if this node is the same as the specified node,
based on whether the two nodes have the same path.

=cut

sub is_same_node_as
{
    my ($self, $node) = @_;

    croak 'Missing node to compare with' unless $node;

    croak 'Invalid node: is not a "DBIx::Tree::MaterializedPath::Node"'
      unless blessed($node) && $node->isa('DBIx::Tree::MaterializedPath::Node');

    return $self->_path eq $node->_path;
}

=head2 is_ancestor_of

    $node->is_ancestor_of( $other_node )

Returns true if this node is an ancestor of the specified node.

Returns false if this node is the same as the specified node.

=cut

sub is_ancestor_of
{
    my ($self, $node) = @_;

    croak 'Missing node' unless $node;

    croak 'Invalid node: is not a "DBIx::Tree::MaterializedPath::Node"'
      unless blessed($node) && $node->isa('DBIx::Tree::MaterializedPath::Node');

    my $mapper = $self->{_root}->{_pathmapper};
    return $mapper->is_ancestor_of($self->_path, $node->_path);
}

=head2 is_descendant_of

    $node->is_descendant_of( $other_node )

Returns true if this node is a descendant of the specified node.

Returns false if this node is the same as the specified node.

=cut

sub is_descendant_of
{
    my ($self, $node) = @_;

    croak 'Missing node' unless $node;

    croak 'Invalid node: is not a "DBIx::Tree::MaterializedPath::Node"'
      unless blessed($node) && $node->isa('DBIx::Tree::MaterializedPath::Node');

    my $mapper = $self->{_root}->{_pathmapper};
    return $mapper->is_descendant_of($self->_path, $node->_path);
}

=head2 depth

Returns the depth of this node in the tree.

The root node is at depth zero.

=cut

sub depth
{
    my ($self) = @_;
    return $self->{_root}->{_pathmapper}->depth($self->_path);
}

#
# Map the path to the node into the format that is stored in
# the database:
#
sub _map_path
{
    my ($self, $path) = @_;
    return $self->{_root}->{_pathmapper}->map($path);
}

#
# Map the path to the node from the format that is stored in
# the database:
#
sub _unmap_path
{
    my ($self, $path) = @_;
    return $self->{_root}->{_pathmapper}->unmap($path);
}

#
# Private methods to load a row from the database into the object:
#

sub _load_from_db_using_id
{
    my ($self, $id) = @_;

    my $sql_key = 'SELECT_STAR_FROM_TABLE_WHERE_ID_EQ_X_LIMIT_1';
    my $sql     = $self->{_root}->_cached_sql($sql_key);

    $self->_load_from_db_using_sql($sql, $id);
}

sub _load_from_db_using_path
{
    my ($self, $path) = @_;

    my $sql_key = 'SELECT_STAR_FROM_TABLE_WHERE_PATH_EQ_X_LIMIT_1';
    my $sql     = $self->{_root}->_cached_sql($sql_key);

    $self->_load_from_db_using_sql($sql, $path);
}

sub _load_id_from_db_using_path
{
    my ($self, $path) = @_;

    my $sql_key = 'SELECT_ID_FROM_TABLE_WHERE_PATH_EQ_X_LIMIT_1';
    my $sql     = $self->{_root}->_cached_sql($sql_key);

    $self->_load_from_db_using_sql($sql, $path);
}

sub _load_from_db_using_sql
{
    my ($self, $sql, @bind_params) = @_;

    my $sth = $self->{_root}->_cached_sth($sql);
    $sth->execute(@bind_params);
    my $row = $sth->fetchrow_hashref();
    $sth->finish;    # in case more than one row was returned
    croak qq{No row [$sql]} unless defined $row;
    $self->_load_from_hashref($row);
}

sub _load_from_hashref
{
    my ($self, $data, $ignore_empty_hash) = @_;

    my $id_col   = $self->{_root}->{_id_column_name};
    my $path_col = $self->{_root}->{_path_column_name};
    $self->{_id}   = delete $data->{$id_col}   if exists $data->{$id_col};
    $self->{_path} = delete $data->{$path_col} if exists $data->{$path_col};

    if ($ignore_empty_hash)
    {
        return unless keys %$data;
    }

    $self->{_data} = $data;
}

sub _insert_into_db_from_hashref
{
    my ($self, $data) = @_;

    my $root = $self->{_root};

    my $path_col = $root->{_path_column_name};
    croak 'Cannot insert without path' unless $data->{$path_col};

    my $sqlmaker = $root->{_sqlmaker};
    my ($sql, @bind_params) =
      $sqlmaker->insert($self->{_root}->{_table_name}, $data);

    my $sth;
    eval { $sth = $root->_cached_sth($sql); };
    croak 'Node data (probably) contains invalid column name(s)' if $@;

    $sth->execute(@bind_params);

    # Need to load newly-created id from database:
    $self->_load_id_from_db_using_path($data->{$path_col});

    # Update in-memory copy to stay consistent with database:
    $self->_load_from_hashref($data);
}

#
# Private accessors:
#

sub _id
{
    my ($self) = @_;
    return $self->{_id};
}

#
# (Optionally sets and) returns the path stored with the node.
# Setting the path will update the row in the database.
# Getting the path will return the path stored in the node,
# or will query the database using the node ID if the path has
# not yet been loaded.
#
sub _path
{
    my ($self, $path) = @_;

    my $id = $self->{_id};

    if ($path)
    {
        my $sql_key = 'UPDATE_TABLE_SET_PATH_EQ_X_WHERE_ID_EQ_X';
        my $root    = $self->{_root};
        my $sql     = $root->_cached_sql($sql_key);
        my $sth     = $root->_cached_sth($sql);

        $sth->execute($path, $id);

        # Update in-memory copy to stay consistent with database:
        $self->{_path} = $path;
    }
    elsif (!exists $self->{_path})
    {
        $self->_load_from_db_using_id($id);
    }

    return $self->{_path};
}

=head2 table_name

Returns the name of the database table in which this tree data
is stored.  Useful when creating JOIN-type queries across multiple
tables for use with L<find()|/find>.

=cut

sub table_name
{
    my ($self) = @_;
    return $self->{_root}->{_table_name};
}

=head2 data

    $node->data( $optional_data_hashref )

(Optionally sets and) returns a hashref of metadata stored with the
node.  Setting data will update the row in the database.  Getting
data will return the data stored in the node, or will query the
database using the node ID if the node data has not yet been loaded.

If setting data, note that each key of the hash must correspond
to a column of the same name that already exists in the database
table.

Will croak if data is not a HASHREF or is an empty hash.

Will croak if the data hash contains keys which match either the
L<id_column_name|DBIx::Tree::MaterializedPath/item_id_column_name>
or the
L<path_column_name|DBIx::Tree::MaterializedPath/item_path_column_name>
as specified in the
L<DBIx::Tree::MaterializedPath|DBIx::Tree::MaterializedPath>
constructor.

=cut

sub data
{
    my ($self, $data) = @_;

    if ($data)
    {
        croak 'Node data must be a HASHREF' unless ref($data) eq 'HASH';
        croak 'Node data is empty' unless keys %$data;

        my $root = $self->{_root};

        my $id_col = $root->{_id_column_name};
        croak 'Node data cannot overwrite id column "$id_col"'
          if exists $data->{$id_col};

        my $path_col = $root->{_path_column_name};
        croak 'Node data cannot overwrite path column "$path_col"'
          if exists $data->{$path_col};

        my $sqlmaker = $root->{_sqlmaker};
        my $where = {$id_col => $self->{_id}};
        my ($sql, @bind_params) =
          $sqlmaker->update($root->{_table_name}, $data, $where);

        my $sth;
        eval { $sth = $root->_cached_sth($sql); };
        croak 'Node data (probably) contains invalid column name(s)' if $@;

        $sth->execute(@bind_params);

        # Update in-memory copy to stay consistent with database:
        $self->_load_from_hashref($data);
    }
    elsif (!exists $self->{_data})
    {
        $self->_load_from_db_using_id($self->{_id});
    }

    return $self->{_data};
}

=head2 refresh_data

Queries the database using the node ID to refresh the in-memory
copy of the node data.  Returns a hashref of data stored with the
node.

B<Note:> Setting node metadata via L<data()|/data> will keep the database
and in-memory copies of the node metadata in sync.  Only use the
C<refresh_data()> method if you think this node's metadata in the
database may have changed out from under you.

=cut

sub refresh_data
{
    my ($self) = @_;

    my $id = $self->{_id};
    $self->_load_from_db_using_id($id);

    return $self->{_data};
}

=head2 add_children

    $node->add_children( @children )

Add one or more child nodes below this node.  Returns a
reference to a list of the newly-created node objects.
New nodes will be created to the right of any existing children
(i.e. ordered after any existing children).

I<@children> should be a list (or listref) of hashrefs, where
each hashref contains the metadata for a child to be added.

Note: Children with no metadata can be added by passing empty
hashrefs, e.g.:

    $node->add_children({}, {}, {})

=cut

sub add_children
{
    my $self = shift;
    croak 'No input data' unless defined $_[0];
    my $children = ref $_[0] eq 'ARRAY' ? shift : [@_];

    $self->_validate_new_children_data($children);

    my $next_path = $self->_next_child_path();

    my $nodes;

    my $func = sub {
        ($nodes, $next_path) = $self->_add_children($next_path, $children);
    };

    eval { $self->{_root}->_do_transaction($func); };
    croak "add_children() aborted: $@" if $@;

    return $nodes;
}

=head2 add_child

    $node->add_child( $child )

Add a child node below this node.  Returns the newly-created
node object.

I<$child> should be a hashref representing the child to add.

This is just a wrapper for L<add_children()|/add_children>.

=cut

sub add_child
{
    my ($self, $child) = @_;
    my $children = $self->add_children([$child]);
    return $children->[0];
}

=head2 add_children_at_left

    $node->add_children_at_left( @children )

Add one or more child nodes below this node, as the left-most
children (i.e. ordered before any existing children).  Returns
a reference to a list of the newly-created node objects.

B<Note that this requires more work than adding children at the
end of the list (via L<add_children()|/add_children>), since in
this case the paths for any existing children (and all of their
descendants) will need to be updated.>

I<@children> should be a list (or listref) of hashrefs, where
each hashref contains the metadata for a child to be added.

Note: Children with no metadata can be added by passing empty
hashrefs, e.g.:

    $node->add_children_at_left({}, {}, {})

=cut

sub add_children_at_left
{
    my $self = shift;
    croak 'No input data' unless defined $_[0];
    my $children = ref $_[0] eq 'ARRAY' ? shift : [@_];

    # Need to validate new children data first, so we don't
    # needlessly go through the trouble of reparenting existing
    # children if the input data is bad:
    $self->_validate_new_children_data($children);

    my $num_new_children = scalar @$children;

    my $descendants = $self->get_descendants();

    my $root   = $self->{_root};
    my $mapper = $root->{_pathmapper};

    my $first_child_path = $mapper->first_child_path($self->_path);
    my $next_path        = $first_child_path;

    my $initial_depth = $self->depth + 1;

    my $nodes;

    my $func = sub {

        # Need to reparent any existing children first (i.e.
        # shift them to the right), so that the paths of the
        # newly-created children don't collide:
        if (@$descendants)
        {
            $next_path =
              $mapper->next_child_path($next_path, $num_new_children);

            my $coderef = sub {
                my ($node, $parent, $context) = @_;

                if ($node->depth == $initial_depth)
                {
                    $node->_path($next_path);

                    $next_path = $mapper->next_child_path($next_path);
                }
                else
                {
                    $node->_reparent($parent);
                }
            };

            $self->traverse_descendants($descendants, $coderef);
        }

        ($nodes, $next_path) =
          $self->_add_children($first_child_path, $children);
    };

    eval { $root->_do_transaction($func); };
    croak "add_children_at_left() aborted: $@" if $@;

    return $nodes;
}

sub _validate_new_children_data
{
    my ($self, $children) = @_;

    croak 'Input children list is empty' unless @$children;

    my $root     = $self->{_root};
    my $id_col   = $root->{_id_column_name};
    my $path_col = $root->{_path_column_name};

    # Remember any metadata column names we encounter
    # while checking each of the new children:
    my %columns = ();

    foreach my $data (@$children)
    {
        croak 'Node data must be a HASHREF' unless ref($data) eq 'HASH';

        croak 'Node data cannot overwrite id column "$id_col"'
          if exists $data->{$id_col};

        croak 'Node data cannot overwrite path column "$path_col"'
          if exists $data->{$path_col};

        $columns{$_} = 1 foreach keys %$data;
    }

    # Make sure any metadata column names we encountered
    # actually exist, by trying to prepare a database handle
    # which queries for each of them:

    my @columns = sort keys %columns;

    my $sql_key = 'VALIDATE_' . join('', @columns);
    my $sql = $self->{_root}->_cached_sql($sql_key, \@columns);

    eval { my $sth = $root->_cached_sth($sql); };
    croak 'Node data (probably) contains invalid column name(s)' if $@;
}

sub _add_children
{
    my ($self, $next_path, $children) = @_;

    my $root     = $self->{_root};
    my $path_col = $root->{_path_column_name};
    my $mapper   = $root->{_pathmapper};

    my @nodes = ();

    foreach my $data (@$children)
    {
        my $child = DBIx::Tree::MaterializedPath::Node->new($root);
        my $child_data = {%$data, $path_col => $next_path};
        $child->_insert_into_db_from_hashref($child_data);
        push @nodes, $child;

        $next_path = $mapper->next_child_path($next_path);
    }

    return (\@nodes, $next_path);
}

=head2 get_parent

Returns this node's parent node, or undef if this node is
the root.

=cut

sub get_parent
{
    my ($self) = @_;

    return undef if $self->{_is_root};

    my $sql_key = 'SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_PARENT';

    my ($sql, $bind_params) = $self->_cached_node_sql_info($sql_key);

    my $sth = $self->{_root}->_cached_sth($sql);
    $sth->execute(@$bind_params);

    my $row = $sth->fetchrow_hashref();
    $sth->finish;    # in case more than one row was returned
    croak qq{No row [$sql]} unless defined $row;

    my $parent = DBIx::Tree::MaterializedPath::Node->new($self->{_root});
    $parent->_load_from_hashref($row);

    return $parent;
}

sub _reparent
{
    my ($self, $parent) = @_;

    $parent ||= $self->get_parent;

    my $parent_path   = $parent->_path;
    my $prefix_length = length $parent_path;
    my $path          = $self->_path;
    substr($path, 0, $prefix_length) = $parent_path;
    $self->_path($path);
}

=head2 get_children

    $node->get_children( $options_hashref )

Returns a reference to a (possibly empty) ordered list of direct
child nodes.

By default, any node metadata stored in the database is retrieved
by the database SELECT and is populated in each of the
corresponding node objects.

If the optional parameters hashref contains a true value for
"B<delay_load>", then the metadata will not be retrieved from the
database until the L<data()|/data> method is called on a given
node.

=cut

sub get_children
{
    my $self = shift;
    my $options = ref $_[0] eq 'HASH' ? shift : {@_};

    my $delay_load = $options->{delay_load} ? 1 : 0;

    my $sql_key =
      $delay_load
      ? 'SELECT_IDPATH_FROM_TABLE_WHERE_PATH_FINDS_CHILDREN'
      : 'SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_CHILDREN';

    my ($sql, $bind_params) = $self->_cached_node_sql_info($sql_key);

    my $sth = $self->{_root}->_cached_sth($sql);
    $sth->execute(@$bind_params);

    my $rows = $sth->fetchall_arrayref({});    # fetch array of hashrefs

    return $self->_nodes_from_hashrefs($rows, $delay_load);
}

=head2 get_siblings

    $node->get_siblings( $options_hashref )

Returns a reference to an ordered list of sibling nodes.

B<Note:> The list will always contain at least one node, i.e.
the current node on which the method is being called.

By default, any node metadata stored in the database is retrieved
by the database SELECT and is populated in each of the
corresponding node objects.

If the optional parameters hashref contains a true value for
"B<delay_load>", then the metadata will not be retrieved from the
database until the L<data()|/data> method is called on a given
node.

=cut

sub get_siblings
{
    my $self = shift;
    my $options = ref $_[0] eq 'HASH' ? shift : {@_};

    my $delay_load = $options->{delay_load} ? 1 : 0;

    my $sql_key =
      $delay_load
      ? 'SELECT_IDPATH_FROM_TABLE_WHERE_PATH_FINDS_SIBLINGS'
      : 'SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_SIBLINGS';

    my ($sql, $bind_params) = $self->_cached_node_sql_info($sql_key);

    my $sth = $self->{_root}->_cached_sth($sql);
    $sth->execute(@$bind_params);

    my $rows = $sth->fetchall_arrayref({});    # fetch array of hashrefs

    return $self->_nodes_from_hashrefs($rows, $delay_load);
}

=head2 get_siblings_to_the_right

    $node->get_siblings_to_the_right( $options_hashref )

Returns a reference to an ordered list of any sibling nodes
to the right of this node.

B<Note:> The list will B<not> contain the current node.

By default, any node metadata stored in the database is retrieved
by the database SELECT and is populated in each of the
corresponding node objects.

If the optional parameters hashref contains a true value for
"B<delay_load>", then the metadata will not be retrieved from the
database until the L<data()|/data> method is called on a given
node.

=cut

sub get_siblings_to_the_right
{
    my $self = shift;
    return $self->_get_siblings_to_one_side('RIGHT', @_);
}

=head2 get_siblings_to_the_left

    $node->get_siblings_to_the_left( $options_hashref )

Returns a reference to an ordered list of any sibling nodes
to the left of this node.

B<Note:> The list will B<not> contain the current node.

By default, any node metadata stored in the database is retrieved
by the database SELECT and is populated in each of the
corresponding node objects.

If the optional parameters hashref contains a true value for
"B<delay_load>", then the metadata will not be retrieved from the
database until the L<data()|/data> method is called on a given
node.

=cut

sub get_siblings_to_the_left
{
    my $self = shift;
    return $self->_get_siblings_to_one_side('LEFT', @_);
}

sub _get_siblings_to_one_side
{
    my $self    = shift;
    my $side    = shift;
    my $options = ref $_[0] eq 'HASH' ? shift : {@_};

    $side = 'RIGHT' unless $side eq 'LEFT';

    my $delay_load = $options->{delay_load} ? 1 : 0;

    my $sql_key =
      $delay_load
      ? 'SELECT_IDPATH_FROM_TABLE_WHERE_PATH_FINDS_SIBLINGS_TO_THE_' . $side
      : 'SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_SIBLINGS_TO_THE_' . $side;

    my ($sql, $bind_params) = $self->_cached_node_sql_info($sql_key);

    my $sth = $self->{_root}->_cached_sth($sql);
    $sth->execute(@$bind_params);

    my $rows = $sth->fetchall_arrayref({});    # fetch array of hashrefs

    return $self->_nodes_from_hashrefs($rows, $delay_load);
}

#
# Given an array of hashrefs, create an array of nodes:
#
sub _nodes_from_hashrefs
{
    my ($self, $hashrefs, $delay_load) = @_;

    my $root = $self->{_root};

    my @nodes = ();

    foreach my $hashref (@$hashrefs)
    {
        my $node = DBIx::Tree::MaterializedPath::Node->new($root);
        $node->_load_from_hashref($hashref, $delay_load);
        push @nodes, $node;
    }

    return \@nodes;
}

=head2 get_descendants

    $node->get_descendants( $options_hashref )

Returns a reference to a (possibly empty) list of hashrefs
which in turn contain all of a node's descendant nodes.

E.g. calling C<get_descendants()> on node "E" below:

              A
           ___|_____
          |         |
          B         E
         _|_     ___|___
        |   |   |   |   |
        C   D   F   I   J
               _|_
              |   |
              G   H

results in:

    [
      {
        node     => DBIx::Tree::MaterializedPath::Node "F",
        children => [
                      {
                        node     => DBIx::Tree::MaterializedPath::Node "G",
                        children => [],
                      },
                      {
                        node     => DBIx::Tree::MaterializedPath::Node "H",
                        children => [],
                      },
                    ],
      },
      {
        node     => DBIx::Tree::MaterializedPath::Node "I",
        children => [],
      },
      {
        node     => DBIx::Tree::MaterializedPath::Node "J",
        children => [],
      },
    ]

By default, any node metadata stored in the database is retrieved
by the database SELECT and is populated in each of the
corresponding node objects.

If the optional parameters hashref contains a true value for
"B<delay_load>", then the metadata will not be retrieved from the
database until the L<data()|/data> method is called on a given
node.

=cut

sub get_descendants
{
    my $self = shift;
    my $options = ref $_[0] eq 'HASH' ? shift : {@_};

    my $delay_load = $options->{delay_load} ? 1 : 0;

    my $sql_key =
      $delay_load
      ? 'SELECT_IDPATH_FROM_TABLE_WHERE_PATH_FINDS_DESCENDANTS'
      : 'SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_DESCENDANTS';

    my ($sql, $bind_params) = $self->_cached_node_sql_info($sql_key);

    my $sth = $self->{_root}->_cached_sth($sql);
    $sth->execute(@$bind_params);

    my $rows = $sth->fetchall_arrayref({});    # fetch array of hashrefs

    # Rows are sorted by path, e.g:
    #    { id => 2, name => "a", path => "1.1"     },
    #    { id => 3, name => "b", path => "1.2"     },
    #    { id => 4, name => "c", path => "1.3"     },
    #    { id => 5, name => "d", path => "1.3.1"   },
    #    { id => 7, name => "f", path => "1.3.1.1" },
    #    { id => 6, name => "e", path => "1.3.2"   },

    sub _add_descendant_nodes
    {
        my ($root, $path_col, $nodes, $rows, $prev_path, $prev_length,
            $delay_load)
          = @_;

        my $node_children = undef;

        while (@$rows)
        {
            my $path   = $rows->[0]->{$path_col};
            my $length = length $path;

            # If path length is less, we've gone back up
            # a level in the tree:
            if ($length < $prev_length)
            {
                return;
            }

            # If path length is greater, we've gone down
            # a level in the tree:
            elsif ($length > $prev_length)
            {
                _add_descendant_nodes($root, $path_col, $node_children, $rows,
                                      $prev_path, $length, $delay_load);
            }

            # If path length is the same, we're adding
            # siblings at the same level:
            else
            {
                my $row = shift @$rows;

                if ($row->{$path_col} eq $prev_path)
                {
                    carp "Danger! Found multiple rows with path <$path>";
                }
                else
                {
                    $prev_path = $row->{$path_col};
                }

                my $child = DBIx::Tree::MaterializedPath::Node->new($root);
                $child->_load_from_hashref($row, $delay_load);
                $node_children = [];
                push @$nodes, {node => $child, children => $node_children};
            }
        }
    }

    my @nodes = ();
    if (@$rows)
    {
        my $root     = $self->{_root};
        my $path_col = $root->{_path_column_name};
        my $path     = $rows->[0]->{$path_col};
        my $length   = length $path;
        _add_descendant_nodes($root, $path_col, \@nodes, $rows, '', $length,
                              $delay_load);
    }
    return \@nodes;
}

=head2 traverse_descendants

    $node->traverse_descendants( $descendants, $coderef, $optional_context )

Given a data structure of descendants (as returned by
L<get_descendants()|/get_descendants>) and a coderef, traverse down
the data structure in leftmost depth-first order and apply the
coderef at each node.

The first argument to the I<$coderef> will be the node being
traversed.  The second argument to the I<$coderef> will be that
node's parent.

If supplied, I<$context> will be the third argument to the
coderef.  I<$context> can be a reference to a data structure that
can allow information to be carried along from node to node while
traversing the tree.

E.g. to count the number of descendants:

    my $context = {count => 0};
    my $coderef = sub {
        my ($node, $parent, $context) = @_;
        $context->{count}++;
    };

    my $descendants = $node->get_descendants();
    $node->traverse_descendants($descendants, $coderef, $context);

    print "The node has $context->{count} descendants.\n";

Note that you may be able to use closure variables instead of
passing them along in I<$context>:

    my $count   = 0;
    my $coderef = sub {
        my ($node, $parent) = @_;
        $count++;
    };

    my $descendants = $node->get_descendants();
    $node->traverse_descendants($descendants, $coderef);

    print "The node has $count descendants.\n";

=cut

sub traverse_descendants
{
    my ($self, $descendants, $coderef, $context) = @_;

    croak 'Missing descendants' unless $descendants;
    croak 'Invalid descendants' unless ref($descendants) eq 'ARRAY';
    croak 'Missing coderef'     unless $coderef;
    croak 'Invalid coderef'     unless ref($coderef) eq 'CODE';

    foreach my $child (@$descendants)
    {
        my $node = $child->{node};
        $coderef->($node, $self, $context);

        my $children = $child->{children};
        if (@$children)
        {
            $node->traverse_descendants($children, $coderef, $context);
        }
    }
}

=head2 delete_descendants

Delete any descendant nodes below this node.

=cut

sub delete_descendants
{
    my ($self) = @_;

    my $sql_key = 'DELETE_FROM_TABLE_WHERE_PATH_FINDS_DESCENDANTS';

    my ($sql, $bind_params) = $self->_cached_node_sql_info($sql_key);

    my $sth = $self->{_root}->_cached_sth($sql);
    $sth->execute(@$bind_params);
}

=head2 delete

Delete this node and any descendant nodes below it.

If this node has any siblings to the right, the paths for those
siblings (and for all of their descendants, if any) will be
updated.

B<Don't try to use the node object after you have deleted it!>

Note: The root node of the tree cannot be deleted.

=cut

sub delete
{
    my ($self) = @_;

    croak 'Can\'t delete root node' if $self->{_is_root};

    my $root   = $self->{_root};
    my $mapper = $root->{_pathmapper};

    my $siblings = $self->get_siblings_to_the_right();

    my $deleted_path = $self->_path;
    my $next_path    = $deleted_path;

    my $func = sub {

        # first, delete node and its descendants:
        $self->_delete;

        # Next, need to reparent any siblings to the right,
        # as well as their descendants (if any):

        my $coderef = sub {
            my ($node, $parent, $context) = @_;
            $node->_reparent($parent);
        };

        foreach my $sibling (@$siblings)
        {
            my $descendants = $sibling->get_descendants();

            $sibling->_path($next_path);

            $next_path = $mapper->next_child_path($next_path);

            $sibling->traverse_descendants($descendants, $coderef);
        }
    };

    eval { $root->_do_transaction($func); };
    croak "delete() aborted: $@" if $@;
}

sub _delete
{
    my ($self) = @_;

    my $sql_key = 'DELETE_FROM_TABLE_WHERE_PATH_FINDS_DESCENDANTS_AND_SELF';

    my ($sql, $bind_params) = $self->_cached_node_sql_info($sql_key);

    my $sth = $self->{_root}->_cached_sth($sql);
    $sth->execute(@$bind_params);

    $self->{_deleted} = 1;
}

=head2 find

    $node->find( $options_hashref )

Given an L<SQL::Abstract|SQL::Abstract>-style I<where> clause,
returns a reference to a (possibly empty) ordered list of
descendant nodes that match.

C<find()> accepts a hashref of arguments:

=over 4

=item B<where>

B<Required.>

An L<SQL::Abstract|SQL::Abstract>-style I<where> clause

=item B<extra_tables>

An arrayref of additional table names to include in the SELECT
statement, if the WHERE clause queries across any tables other
than the main table in which the tree resides.

B<Note:> If querying across additional tables, make sure that
the column names referenced in the WHERE clause are correctly
prefixed by the table in which they live.

=item B<order_by>

An arrayref of column names to order the results by.  If specified,
this will override the default ordering by path (i.e. the order the
node's descendants would be traversed).

=item B<delay_load>

By default, any node metadata stored in the database is retrieved
by the database SELECT and is populated in each of the
corresponding node objects.

If the options hashref contains a true value for
"B<delay_load>", then the metadata will not be retrieved from the
database until the L<data()|/data> method is called on a given
node.

=back

For example, if you have metadata columns in your tree table
named "name" and "title", you could do queries like so:

    # name = ?
    #
    $nodes = $node->find(where => {
                                    name => 'exact text',
                                  });

    # name like ?
    #
    $nodes = $node->find(where => {
                                    name => {-like => '%text'},
                                  });

    # (name = ?) OR (name = ?)
    #
    $nodes = $node->find(where => {
                                    name => ['this', 'that'],
                                  });

    # (name = ?) AND (title = ?)
    #
    $nodes = $node->find(where => {
                                    name  => 'this',
                                    title => 'that',
                                  });

    # (name = ?) OR (title = ?)
    #
    # Note: "where" is an arrayref, not a hashref!
    #
    $nodes = $node->find(where => [
                                    {name  => 'this'},
                                    {title => 'that'},
                                  ]);

    # (name like ?) AND (name != ?)
    #
    $nodes = $node->find(where => {
                                    name => [
                                              -and =>
                                              {-like => '%text'},
                                              {'!='  => 'bad text},
                                            ],
                                  });

You can also do JOIN queries across tables using the C<extra_tables>
parameter.  Suppose you have a "movies" table with columns for
"id" and "title", and that your tree table has a metadata column
named "movie_id" which corresponds to the "id" column in the
"movies" table.  You could do queries like so:

    my $table = $node->table_name;    # the table the tree lives in

    # (movies.title like ?) AND (movies.id = my_tree.movie_id)
    #
    # Note the literal backslash before "= $table.movie_id"...
    #
    $nodes = $node->find(extra_tables => ['movies'],
                         where => {
                                    'movies.title' => {-like => 'text%'},
                                    'movies.id'    => \"= $table.movie_id",
                                  });

=cut

sub find
{
    my $self = shift;
    my $options = ref $_[0] eq 'HASH' ? shift : {@_};

    croak 'Missing WHERE data' unless $options->{where};

    my $delay_load = $options->{delay_load} ? 1 : 0;

    my $path  = $self->_path;
    my $root  = $self->{_root};
    my $table = $root->{_table_name};

    # Need column names prefixed by table in case user's WHERE does
    # a query across tables:
    my $id_col   = $table . '.' . $root->{_id_column_name};
    my $path_col = $table . '.' . $root->{_path_column_name};

    my $mapper   = $root->{_pathmapper};
    my $sqlmaker = $root->{_sqlmaker};

    my $tables = $options->{extra_tables} || [];
    push @$tables, $table;

    # This returns the equivalent of WHERE_PATH_FINDS_DESCENDANTS:
    my $descendants_where = $mapper->descendants_where_struct($path_col, $path);

    # Now mix in user's requested WHERE struct:
    my $where = [-and => [$descendants_where, [$options->{where}]]];

    my $columns = $delay_load ? [$id_col, $path_col] : '*';

    my $order_by = $options->{order_by} || [$path_col];

    my ($sql, @bind_params) =
      $sqlmaker->select($tables, $columns, $where, $order_by);

    my $sth = $self->{_root}->_cached_sth($sql);

    $sth->execute(@bind_params);

    my $rows = $sth->fetchall_arrayref({});    # fetch array of hashrefs

    return $self->_nodes_from_hashrefs($rows, $delay_load);
}

=head2 swap_node

    $node->swap_node( $other_node )

Swap locations (i.e. paths) between this node and the
specified node.

B<Any children of the nodes being swapped will remain in
place.>  E.g. swapping "B" and "E" in the tree below:

              A
           ___|_____
          |         |
          B         E
         _|_     ___|___
        |   |   |   |   |
        C   D   F   I   J
               _|_
              |   |
              G   H

results in:

              A
           ___|_____
          |         |
          E         B
         _|_     ___|___
        |   |   |   |   |
        C   D   F   I   J
               _|_
              |   |
              G   H

Note: The root node of the tree cannot be swapped with another
node.

=cut

sub swap_node
{
    my ($self, $node) = @_;

    croak 'Missing node to swap with' unless $node;

    croak 'Invalid node: is not a "DBIx::Tree::MaterializedPath::Node"'
      unless blessed($node) && $node->isa('DBIx::Tree::MaterializedPath::Node');

    croak 'Can\'t swap root node' if $self->{_is_root} || $node->{_is_root};

    return if $self->is_same_node_as($node);

    my $func = sub {
        my ($node1, $node2) = @_;
        my $path1 = $node1->_path;
        my $path2 = $node2->_path;
        $node1->_path($path2);
        $node2->_path($path1);
    };

    eval { $self->{_root}->_do_transaction($func, $self, $node); };
    croak "swap_node() aborted: $@" if $@;
}

=head2 swap_subtree

    $node->swap_subtree( $other_node )

Swap this node (and all of its children) with the
specified node (and all of its children).

Any children of the nodes being swapped will move with them.
E.g. swapping "B" and "E" in the tree below:

              A
           ___|_____
          |         |
          B         E
         _|_     ___|___
        |   |   |   |   |
        C   D   F   I   J
               _|_
              |   |
              G   H

results in:

              A
           ___|_____
          |         |
          E         B
       ___|___     _|_
      |   |   |   |   |
      F   I   J   C   D
     _|_
    |   |
    G   H

Note: Because subtrees are being swapped, a node cannot be
swapped with one of its own ancestors or descendants.

Note: The root node of the tree cannot be swapped with another
node.

=cut

sub swap_subtree
{
    my ($self, $node) = @_;

    croak 'Missing node to swap with' unless $node;

    croak 'Invalid node: is not a "DBIx::Tree::MaterializedPath::Node"'
      unless blessed($node) && $node->isa('DBIx::Tree::MaterializedPath::Node');

    croak 'Can\'t swap root node' if $self->is_root || $node->is_root;

    return if $self->is_same_node_as($node);

    croak 'Can\'t swap node with ancestor/descendant'
      if $self->is_ancestor_of($node) || $self->is_descendant_of($node);

    my $func = sub {
        my ($node1, $node2) = @_;

        # Get descendants *before* swapping:
        my $descendants1 = $node1->get_descendants();
        my $descendants2 = $node2->get_descendants();

        # Swap the node paths:
        my $path1 = $node1->_path;
        my $path2 = $node2->_path;
        $node1->_path($path2);
        $node2->_path($path1);

        # Now update descendants using new paths:
        my $coderef = sub {
            my ($node, $parent, $context) = @_;
            $node->_reparent($parent);
        };
        $node1->traverse_descendants($descendants1, $coderef);
        $node2->traverse_descendants($descendants2, $coderef);
    };

    eval { $self->{_root}->_do_transaction($func, $self, $node); };
    croak "swap_subtree() aborted: $@" if $@;
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
    $clone->{_root} = $self->{_root};

    return $clone;
}

#
# Query for and return the path to the last child of this node:
#
sub _last_child_path
{
    my ($self) = @_;

    my $sql_key = 'SELECT_PATH_FROM_TABLE_WHERE_PATH_FINDS_LAST_CHILD';

    my ($sql, $bind_params) = $self->_cached_node_sql_info($sql_key);

    my $sth = $self->{_root}->_cached_sth($sql);

    $sth->execute(@$bind_params);

    my $row = $sth->fetch();
    $sth->finish;    # in case more than one row was returned
    return (defined $row) ? $row->[0] : '';
}

#
# Return the path to where the next child of this node would be added:
#
sub _next_child_path
{
    my ($self) = @_;

    my $mapper = $self->{_root}->{_pathmapper};

    my $last_child_path = $self->_last_child_path();
    if ($last_child_path)
    {
        return $mapper->next_child_path($last_child_path);
    }
    else
    {
        return $mapper->first_child_path($self->_path);
    }
}

=head2 TODO

TODO

 ancestors()  (is this necessary?)

 move nodes (reparent?)

=cut

###################################################################

#
# Manage a cache of generated SQL:
#

sub _cached_node_sql_info
{
    my ($self, $sql_key, $args) = @_;

    my $path = $self->_path;

    # The cache is keyed on both the SQL key string as well
    # as the path, so if the node path changes new SQL
    # will be generated for it:
    my $sql_info = $self->{_node_sql}->{$sql_key}->{$path};
    unless ($sql_info)
    {
        my $func = "_cached_node_sql_info_$sql_key";
        $sql_info = $self->$func($path, $args);
        $self->{_node_sql}->{$sql_key}->{$path} = $sql_info;
    }
    return ($sql_info->{sql}, $sql_info->{bind_params});
}

sub _cached_node_sql_info_SELECT_PATH_FROM_TABLE_WHERE_PATH_FINDS_LAST_CHILD
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) = $pathmapper->child_where($path_col, $path);

    my $sql = "SELECT $path_col FROM $table $where"
      . " ORDER BY $path_col DESC LIMIT 1";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_DELETE_FROM_TABLE_WHERE_PATH_FINDS_DESCENDANTS
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) =
      $pathmapper->descendants_where($path_col, $path);

    my $sql = "DELETE FROM $table $where";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_DELETE_FROM_TABLE_WHERE_PATH_FINDS_DESCENDANTS_AND_SELF
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) =
      $pathmapper->descendants_and_self_where($path_col, $path);

    my $sql = "DELETE FROM $table $where";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_PARENT
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) = $pathmapper->parent_where($path_col, $path);

    my $sql = "SELECT * FROM $table $where LIMIT 1";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_IDPATH_FROM_TABLE_WHERE_PATH_FINDS_CHILDREN
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $id_col     = $root->{_id_column_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) = $pathmapper->child_where($path_col, $path);

    my $sql = "SELECT $id_col, $path_col FROM $table $where ORDER BY $path_col";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_CHILDREN
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) = $pathmapper->child_where($path_col, $path);

    my $sql = "SELECT * FROM $table $where ORDER BY $path_col";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_IDPATH_FROM_TABLE_WHERE_PATH_FINDS_SIBLINGS
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $id_col     = $root->{_id_column_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) = $pathmapper->sibling_where($path_col, $path);

    my $sql = "SELECT $id_col, $path_col FROM $table $where ORDER BY $path_col";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_SIBLINGS
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) = $pathmapper->sibling_where($path_col, $path);

    my $sql = "SELECT * FROM $table $where ORDER BY $path_col";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_IDPATH_FROM_TABLE_WHERE_PATH_FINDS_SIBLINGS_TO_THE_RIGHT
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $id_col     = $root->{_id_column_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) =
      $pathmapper->sibling_to_the_right_where($path_col, $path);

    my $sql = "SELECT $id_col, $path_col FROM $table $where ORDER BY $path_col";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_SIBLINGS_TO_THE_RIGHT
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) =
      $pathmapper->sibling_to_the_right_where($path_col, $path);

    my $sql = "SELECT * FROM $table $where ORDER BY $path_col";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_IDPATH_FROM_TABLE_WHERE_PATH_FINDS_SIBLINGS_TO_THE_LEFT
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $id_col     = $root->{_id_column_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) =
      $pathmapper->sibling_to_the_left_where($path_col, $path);

    my $sql = "SELECT $id_col, $path_col FROM $table $where ORDER BY $path_col";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_SIBLINGS_TO_THE_LEFT
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) =
      $pathmapper->sibling_to_the_left_where($path_col, $path);

    my $sql = "SELECT * FROM $table $where ORDER BY $path_col";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_IDPATH_FROM_TABLE_WHERE_PATH_FINDS_DESCENDANTS
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $id_col     = $root->{_id_column_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) =
      $pathmapper->descendants_where($path_col, $path);

    my $sql = "SELECT $id_col, $path_col FROM $table $where ORDER BY $path_col";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

sub _cached_node_sql_info_SELECT_STAR_FROM_TABLE_WHERE_PATH_FINDS_DESCENDANTS
{
    my ($self, $path, $args) = @_;

    my $root       = $self->{_root};
    my $table      = $root->{_table_name};
    my $path_col   = $root->{_path_column_name};
    my $pathmapper = $root->{_pathmapper};
    my ($where, @bind_params) =
      $pathmapper->descendants_where($path_col, $path);

    my $sql = "SELECT * FROM $table $where ORDER BY $path_col";

    return {
            sql         => $sql,
            bind_params => \@bind_params,
           };
}

###################################################################

1;

__END__

=head1 SEE ALSO

L<DBIx::Tree::MaterializedPath|DBIx::Tree::MaterializedPath>

L<SQL::Abstract|SQL::Abstract>

=head1 AUTHOR

Larry Leszczynski, C<< <larryl at cpan.org> >>

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

=head1 COPYRIGHT & LICENSE

Copyright 2008 Larry Leszczynski, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

