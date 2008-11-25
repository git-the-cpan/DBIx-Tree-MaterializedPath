package DBIx::Tree::MaterializedPath::TreeRepresentation;

use warnings;
use strict;

use Carp;
use Scalar::Util qw(blessed);

use Readonly;

Readonly::Scalar my $EMPTY_STRING => q{};

use DBIx::Tree::MaterializedPath::Node;

=head1 NAME

DBIx::Tree::MaterializedPath::TreeRepresentation - data structure for "materialized path" trees

=head1 VERSION

Version 0.05

=cut

use version 0.74; our $VERSION = qv('0.05');

=head1 SYNOPSIS

    # Row data must be sorted by path:
    my $subtree_data = [
                        {id => 2, path => "1.1",     name => "a"},
                        {id => 3, path => "1.2",     name => "b"},
                        {id => 4, path => "1.3",     name => "c"},
                        {id => 5, path => "1.3.1",   name => "d"},
                        {id => 7, path => "1.3.1.1", name => "e"},
                        {id => 6, path => "1.3.2",   name => "f"},
                       ];

    my $subtree_representation =
      DBIx::Tree::MaterializedPath::TreeRepresentation->new($node,
                                                            $subtree_data);

    $subtree_representation->traverse($coderef, $context);

=head1 DESCRIPTION

This module implements a data structure that represents a tree
(or subtree) as stored in the database.

See
L<get_descendants()|DBIx::Tree::MaterializedPath::Node/get_descendants>.

=head1 METHODS

=head2 new

    $subtree_data =
      DBIx::Tree::MaterializedPath::TreeRepresentation->new($node,
                                                            $rows_listref,
                                                            $options_hashref);

C<new()> expects a
L<DBIx::Tree::MaterializedPath::Node|DBIx::Tree::MaterializedPath::Node>
object (representing the node that this data belongs to), and a
listref of hashrefs, each of which represents a node row in the
database.

At minimum, each hashref must contain entries for the
L<id_column_name|DBIx::Tree::MaterializedPath/id_column_name>
and the
L<path_column_name|DBIx::Tree::MaterializedPath/path_column_name>
as specified in the
L<DBIx::Tree::MaterializedPath|DBIx::Tree::MaterializedPath>
constructor.  The rows should be sorted by path in ascending order.

Additionally, the hashref may contain entries for
any metadata columns which are stored with the nodes.

One L<DBIx::Tree::MaterializedPath::Node> object will be created in
the data structure for each input row.  If the optional parameters
hashref contains a true value for "B<ignore_empty_hash>", and if no
metadata entries exist in the input row, then the node object's
metadata will not be populated, and will only be retrieved
from the database when the L<data()|/data> method is called on a
given node.

=cut

sub new
{
    my ($class, $node, $rows, @args) = @_;

    croak 'Missing node' unless $node;
    croak 'Invalid node: is not a "DBIx::Tree::MaterializedPath::Node"'
      unless blessed($node) && $node->isa('DBIx::Tree::MaterializedPath::Node');

    croak 'Missing rows' unless $rows;
    croak 'Invalid rows' unless ref($rows) eq 'ARRAY';

    my $options = ref $args[0] eq 'HASH' ? $args[0] : {@args};

    my $ignore_empty_hash = $options->{ignore_empty_hash} ? 1 : 0;

    my $self = bless {}, ref($class) || $class;

    $self->{_node} = $node;

    # E.g. calling C<get_descendants()> on node "E" below:
    #
    #           A
    #        ___|_____
    #       |         |
    #       B         E
    #      _|_     ___|___
    #     |   |   |   |   |
    #     C   D   F   I   J
    #            _|_
    #           |   |
    #           G   H
    #
    # might produce database rows that look like this:
    #
    # [
    #   {id =>  6, path => "1.2.1",   name => "F"},
    #   {id =>  7, path => "1.2.1.1", name => "G"},
    #   {id =>  8, path => "1.2.1.2", name => "H"},
    #   {id =>  9, path => "1.2.2",   name => "I"},
    #   {id => 10, path => "1.2.3",   name => "J"},
    # ]
    #
    # which results in the following data structure:
    #
    # [
    #   {
    #     node     => DBIx::Tree::MaterializedPath::Node "F",
    #     children => [
    #                   {
    #                     node     => DBIx::Tree::MaterializedPath::Node "G",
    #                     children => [],
    #                   },
    #                   {
    #                     node     => DBIx::Tree::MaterializedPath::Node "H",
    #                     children => [],
    #                   },
    #                 ],
    #   },
    #   {
    #     node     => DBIx::Tree::MaterializedPath::Node "I",
    #     children => [],
    #   },
    #   {
    #     node     => DBIx::Tree::MaterializedPath::Node "J",
    #     children => [],
    #   },
    # ]

    my $root = $node->get_root;

    my $num_nodes = 0;
    my @nodes     = ();

    if (@{$rows})
    {
        my $path_col = $root->{_path_column_name};
        my $path     = $rows->[0]->{$path_col};
        my $length   = length $path;
        _add_descendant_nodes(
                              {
                               root              => $root,
                               path_col          => $path_col,
                               nodes             => \@nodes,
                               num_nodes_ref     => \$num_nodes,
                               rows              => $rows,
                               prev_path         => $EMPTY_STRING,
                               prev_length       => $length,
                               ignore_empty_hash => $ignore_empty_hash
                              }
                             );
    }

    $self->{_descendants} = \@nodes;
    $self->{_num_nodes}   = $num_nodes;
    $self->{_has_nodes}   = $self->{_num_nodes} ? 1 : 0;

    return $self;
}

sub _add_descendant_nodes
{
    my ($args) = @_;

    my $root              = $args->{root};
    my $path_col          = $args->{path_col};
    my $nodes             = $args->{nodes};
    my $num_nodes_ref     = $args->{num_nodes_ref};
    my $rows              = $args->{rows};
    my $prev_path         = $args->{prev_path};
    my $prev_length       = $args->{prev_length};
    my $ignore_empty_hash = $args->{ignore_empty_hash};

    my $node_children = undef;

    while (@{$rows})
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
            _add_descendant_nodes(
                                  {
                                   root              => $root,
                                   path_col          => $path_col,
                                   nodes             => $node_children,
                                   num_nodes_ref     => $num_nodes_ref,
                                   rows              => $rows,
                                   prev_path         => $prev_path,
                                   prev_length       => $length,
                                   ignore_empty_hash => $ignore_empty_hash
                                  }
                                 );
        }

        # If path length is the same, we're adding
        # siblings at the same level:
        else
        {
            my $row = shift @{$rows};

            if ($row->{$path_col} eq $prev_path)
            {
                carp "Danger! Found multiple rows with path <$path>";
            }
            else
            {
                $prev_path = $row->{$path_col};
            }

            my $child = DBIx::Tree::MaterializedPath::Node->new($root);
            $child->_load_from_hashref($row, $ignore_empty_hash);
            $node_children = [];
            push @{$nodes}, {node => $child, children => $node_children};
            ${$num_nodes_ref}++;
        }
    }

    return;
}

=head2 has_nodes

   $subtree_data->has_nodes()

Return true if the data structure contains any nodes.

=cut

sub has_nodes
{
    my ($self) = @_;
    return $self->{_has_nodes};
}

=head2 num_nodes

   $subtree_data->num_nodes()

Return the number of nodes in the data structure.

=cut

sub num_nodes
{
    my ($self) = @_;
    return $self->{_num_nodes};
}

=head2 traverse

    $subtree_data->traverse( $coderef, $optional_context )

Given a coderef, traverse down the data structure in leftmost
depth-first order and apply the coderef at each node.

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
    $descendants->traverse($coderef, $context);

    print "The node has $context->{count} descendants.\n";

Note that you may be able to use closure variables instead of
passing them along in I<$context>:

    my $count   = 0;
    my $coderef = sub {
        my ($node, $parent) = @_;
        $count++;
    };

    my $descendants = $node->get_descendants();
    $descendants->traverse($coderef, $context);

    print "The node has $count descendants.\n";

=cut

sub traverse
{
    my ($self, $coderef, $context) = @_;

    croak 'Missing coderef' unless $coderef;
    croak 'Invalid coderef' unless ref($coderef) eq 'CODE';

    return unless $self->{_has_nodes};
    $self->_traverse($self->{_node}, $self->{_descendants}, $coderef, $context);

    return;
}

sub _traverse
{
    my ($self, $parent, $descendants, $coderef, $context) = @_;

    foreach my $child (@{$descendants})
    {
        my $node = $child->{node};
        $coderef->($node, $parent, $context);

        my $children = $child->{children};
        if (@{$children})
        {
            $self->_traverse($node, $children, $coderef, $context);
        }
    }

    return;
}

###################################################################

1;

__END__

=head1 SEE ALSO

L<DBIx::Tree::MaterializedPath|DBIx::Tree::MaterializedPath>

L<DBIx::Tree::MaterializedPath::Node|DBIx::Tree::MaterializedPath::Node>

L<DBIx::Tree::MaterializedPath::PathMapper|DBIx::Tree::MaterializedPath::PathMapper>

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

