#!/usr/bin/env perl
#
#   Copyright (c) International Business Machines  Corp., 2002,2012
#
#   This program is free software;  you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or (at
#   your option) any later version.
#
#   This program is distributed in the hope that it will be useful, but
#   WITHOUT ANY WARRANTY;  without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#   General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program;  if not, see
#   <http://www.gnu.org/licenses/>.
#
#
# genhtml
#
#   This script generates HTML output from .info files as created by the
#   geninfo script. Call it with --help and refer to the genhtml man page
#   to get information on usage and available options.
#
#
# History:
#   2002-08-23 created by Peter Oberparleiter <Peter.Oberparleiter@de.ibm.com>
#                         IBM Lab Boeblingen
#        based on code by Manoj Iyer <manjo@mail.utexas.edu> and
#                         Megan Bock <mbock@us.ibm.com>
#                         IBM Austin
#   2002-08-27 / Peter Oberparleiter: implemented frame view
#   2002-08-29 / Peter Oberparleiter: implemented test description filtering
#                so that by default only descriptions for test cases which
#                actually hit some source lines are kept
#   2002-09-05 / Peter Oberparleiter: implemented --no-sourceview
#   2002-09-05 / Mike Kobler: One of my source file paths includes a "+" in
#                the directory name.  I found that genhtml.pl died when it
#                encountered it. I was able to fix the problem by modifying
#                the string with the escape character before parsing it.
#   2002-10-26 / Peter Oberparleiter: implemented --num-spaces
#   2003-04-07 / Peter Oberparleiter: fixed bug which resulted in an error
#                when trying to combine .info files containing data without
#                a test name
#   2003-04-10 / Peter Oberparleiter: extended fix by Mike to also cover
#                other special characters
#   2003-04-30 / Peter Oberparleiter: made info write to STDERR, not STDOUT
#   2003-07-10 / Peter Oberparleiter: added line checksum support
#   2004-08-09 / Peter Oberparleiter: added configuration file support
#   2005-03-04 / Cal Pierog: added legend to HTML output, fixed coloring of
#                "good coverage" background
#   2006-03-18 / Marcus Boerger: added --custom-intro, --custom-outro and
#                overwrite --no-prefix if --prefix is present
#   2006-03-20 / Peter Oberparleiter: changes to custom_* function (rename
#                to html_prolog/_epilog, minor modifications to implementation),
#                changed prefix/noprefix handling to be consistent with current
#                logic
#   2006-03-20 / Peter Oberparleiter: added --html-extension option
#   2008-07-14 / Tom Zoerner: added --function-coverage command line option;
#                added function table to source file page
#   2008-08-13 / Peter Oberparleiter: modified function coverage
#                implementation (now enabled per default),
#                introduced sorting option (enabled per default)
#   April/May 2020 / Henry Cox/Steven Dovich - Mediatek, inc
#                Add support for differential line coverage categorization,
#                date- and owner- binning.
#   June/July 2020 / Henry Cox - Mediatek, inc
#                Add support for differential branch coverage categorization,
#                Add a bunch of navigation features - href to next code block
#                of type T, of type T in date- or owner bin B, etc.
#                Add sorted tables for date/owner bin summaries.
#   Ocober 2020 / Henry Cox - Mediatek, inc
#                Add "--hierarchical" display option.
#

use strict;
use warnings;

use File::Basename;
use File::Path;
use File::Spec;
use File::Temp;
use Getopt::Long;
use Digest::MD5 qw(md5_base64);
use Cwd qw/abs_path realpath cwd/;
use DateTime;
# using W3CDTF only if annotations are enabled
#use DateTime::Format::W3CDTF;
#use Regexp::Common qw(time);  # damn - not installed
use Date::Parse;
use FileHandle;
use Carp;
use Storable qw(dclone);
use FindBin;
use Time::HiRes;    # for profiling
use Storable;

use lib "$FindBin::Bin/../lib";
use lcovutil qw (set_tool_name define_errors parse_ignore_errors
                 $tool_name $tool_dir $lcov_version $lcov_url
                 ignorable_error
                 $ERROR_MISMATCH $ERROR_SOURCE $ERROR_BRANCH $ERROR_FORMAT
                 $ERROR_EMPTY $ERROR_VERSION $ERROR_UNUSED $ERROR_PACKAGE
                 $ERROR_CORRUPT $ERROR_NEGATIVE $ERROR_COUNT $ERROR_UNSUPPORTED
                 $ERROR_PARALLEL report_parallel_error
                 info $verbose init_verbose_flag
                 do_mangle_check
                 apply_rc_params
                 strip_directories
                 set_rtl_extensions set_c_extensions
                 parse_cov_filters summarize_cov_filters
                 $FILTER_BRANCH_NO_COND $FILTER_LINE_CLOSE_BRACE @cov_filter
                 rate get_overall_line $default_precision check_precision
                 die_handler warn_handler);

# Global constants
our $title = "LCOV - differential code coverage report";
lcovutil::set_tool_name(basename($0));

# Specify coverage rate limits (in %) for classifying file entries
# HI:   $hi_limit <= rate <= 100          graph color: green
# MED: $med_limit <= rate <  $hi_limit    graph color: orange
# LO:          0  <= rate <  $med_limit   graph color: red

# For line coverage/all coverage types if not specified
our $hi_limit  = 90;
our $med_limit = 75;

# For function coverage
our $fn_hi_limit;
our $fn_med_limit;

# For branch coverage
our $br_hi_limit;
our $br_med_limit;

# Width of overview image
our $overview_width = 80;

# Resolution of overview navigation: this number specifies the maximum
# difference in lines between the position a user selected from the overview
# and the position the source code window is scrolled to.
our $nav_resolution = 4;

# Clicking a line in the overview image should show the source code view at
# a position a bit further up so that the requested line is not the first
# line in the window. This number specifies that offset in lines.
our $nav_offset = 10;

# Clicking on a function name should show the source code at a position a
# few lines before the first line of code of that function. This number
# specifies that offset in lines.
our $func_offset = 2;

our $overview_title = "top level";

# Width for line coverage information in the source code view
our $line_field_width = 12;

# Width for branch coverage information in the source code view
our $br_field_width = 16;

# Internal Constants

# Header types
our $HDR_DIR      = 0;
our $HDR_FILE     = 1;
our $HDR_SOURCE   = 2;
our $HDR_TESTDESC = 3;
our $HDR_FUNC     = 4;

# Sort types
our $SORT_FILE   = 0;
our $SORT_LINE   = 1;
our $SORT_FUNC   = 2;
our $SORT_BRANCH = 3;

# Fileview heading types
our $HEAD_NO_DETAIL     = 1;
our $HEAD_DETAIL_HIDDEN = 2;
our $HEAD_DETAIL_SHOWN  = 3;

# Additional offsets used when converting branch coverage data to HTML
our $BR_LEN   = 3;
our $BR_OPEN  = 4;
our $BR_CLOSE = 5;

# Branch data combination types
our $BR_SUB = 0;
our $BR_ADD = 1;

# Error classes which users may specify to ignore during processing
our $ERROR_SOURCE            = 0;
our $ERROR_UNMAPPED_LINE     = 1;
our $ERROR_UNKNOWN_CATEGORY  = 2;
our $ERROR_INCONSISTENT_PATH = 3;
our $ERROR_INCONSISTENT_DATA = 4;
$ERROR_MISMATCH = 5;
$ERROR_BRANCH   = 6;
$ERROR_VERSION  = 7;
$ERROR_UNUSED   = 8;
$ERROR_FORMAT   = 9;
$ERROR_EMPTY    = 10;
our $ERROR_ANNOTATE_SCRIPT = 11;
$ERROR_PARALLEL    = 12;
$ERROR_PACKAGE     = 13;
$ERROR_CORRUPT     = 14;
$ERROR_NEGATIVE    = 15;
$ERROR_COUNT       = 16;
$ERROR_UNSUPPORTED = 17;

our %htmlErrs = ("source"       => $ERROR_SOURCE,
                 "unmapped"     => $ERROR_UNMAPPED_LINE,
                 "category"     => $ERROR_UNKNOWN_CATEGORY,
                 "path"         => $ERROR_INCONSISTENT_PATH,
                 "inconsistent" => $ERROR_INCONSISTENT_DATA,
                 "mismatch"     => $ERROR_MISMATCH,
                 "branch"       => $ERROR_BRANCH,
                 "format"       => $ERROR_FORMAT,
                 "empty"        => $ERROR_EMPTY,
                 "annotate"     => $ERROR_ANNOTATE_SCRIPT,
                 "version"      => $ERROR_VERSION,
                 "unused"       => $ERROR_UNUSED,
                 "parallel"     => $ERROR_PARALLEL,
                 "package"      => $ERROR_PACKAGE,
                 "negative"     => $ERROR_NEGATIVE,
                 "count"        => $ERROR_COUNT,
                 "unsupported"  => $ERROR_UNSUPPORTED,
                 "corrupt"      => $ERROR_CORRUPT,);
lcovutil::define_errors(\%htmlErrs);

# Data related prototypes
sub print_usage(*);
sub gen_html();
sub html_create($$);
sub process_file($$$$$);
sub get_prefix($@);
sub shorten_prefix($);
sub get_relative_base_path($);
sub read_testfile($);
sub get_date_string($);
sub create_sub_dir($);
sub remove_unused_descriptions();
sub get_affecting_tests($$$);
sub apply_prefix($@);
sub get_html_prolog($);
sub get_html_epilog($);
#sub write_dir_page($$$$$$$;$);
sub write_summary_pages($$$$$$$$);
sub classify_rate($$$$);
sub parse_dir_prefix(@);

# HTML related prototypes
sub escape_html($);
sub get_bar_graph_code($$$);

sub write_png_files();
sub write_htaccess_file();
sub write_css_file();
sub write_description_file($$);
sub write_function_table(*$$$$$$$$$$);

sub write_html(*$);
sub write_html_prolog(*$$);
sub write_html_epilog(*$;$);

sub write_header(*$$$$$);
sub write_header_prolog(*$);
sub write_header_line(*@);
sub write_header_epilog(*$);

sub write_file_table(*$$$$);
sub write_file_table_prolog(*$$$@);
sub write_file_table_entry(*$$@);
sub write_file_table_detail_entry(*$$$@);
sub write_file_table_epilog(*);

sub write_test_table_prolog(*$);
sub write_test_table_entry(*$$);
sub write_test_table_epilog(*);

sub write_source($$$$$$$);
sub write_source_prolog(**);
sub write_source_line(*$$$$);
sub write_source_epilog(*);

sub write_frameset(*$$$);
sub write_overview_line(*$$$);
sub write_overview(*$$$$);

# External prototype (defined in genpng)
sub gen_png($$$$$@);

package SummaryInfo;

our $coverageCriteriaScript;
our %coverageCriteria;              # hash of name->(type, success 0/1, string)
our $coverageCriteriaStatus = 0;    # set to non-zero if we see any errors

our @tlaPriorityOrder = ("UNC",
                         "LBC",
                         "UIC",
                         "UBC",

                         "GBC",
                         "GIC",
                         "GNC",
                         "CBC",

                         "EUB",
                         "ECB",
                         "DUB",
                         "DCB",);

our %tlaLocation = ("UNC" => 1,
                    "LBC" => 3,
                    "UIC" => 3,
                    "UBC" => 3,

                    "GBC" => 3,
                    "GIC" => 3,
                    "GNC" => 1,
                    "CBC" => 3,

                    "EUB" => 3,
                    "ECB" => 3,
                    "DUB" => 2,
                    "DCB" => 2,);

our %tlaToTitle = ("UNC" => "Uncovered New Code",
                   "LBC" => "Lost Baseline Coverage",
                   "UIC" => "Uncovered Included Code",
                   "UBC" => "Uncovered Baseline Code",

                   "GBC" => "Gain Baseline Coverage",
                   "GIC" => "Gain Included Coverage",
                   "GNC" => "Gain New Coverage",
                   "CBC" => "Covered Baseline Code",

                   "EUB" => "Excluded Uncovered Baseline",
                   "ECB" => "Excluded Covered Baseline",
                   "DUB" => "Deleted Uncovered Baseline",
                   "DCB" => "Deleted Covered Baseline",);

our %tlaToLegacy = ("UNC" => "Missed",
                    "GNC" => "Hit",);

our %tlaToLegacySrcLabel = ("UNC" => "MIS",
                            "GNC" => "HIT",);

our @defaultCutpoints = (7, 30, 180);
our @cutpoints;
our @ageGroupHeader;
our %ageHeaderToBin;

sub _initCounts
{
    my ($self, $type) = @_;

    my $hash;
    if (defined($type)) {
        $self->{$type} = {};
        $hash = $self->{$type};
    } else {
        $hash = $self;
    }

    foreach my $key ('found', 'hit', 'GNC', 'UNC', 'CBC', 'GBC',
                     'LBC', 'UBC', 'ECB', 'EUB', 'GIC', 'UIC',
                     'DCB', 'DUB'
    ) {
        $hash->{$key} = 0;
    }
}

sub noBaseline
{
    # no baseline - so we will have only 'UIC' and 'GIC' code
    #   legacy display order is 'hit' followed by 'not hit'
    @tlaPriorityOrder = ('GNC', 'UNC');
    %tlaToTitle = ('UNC' => 'Not Hit',
                   'GNC' => 'Hit',);
}

sub setAgeGroups
{
    #my $numGroups = scalar(@_) + 1;
    @cutpoints      = sort({ $a <=> $b } @_);
    @ageGroupHeader = ();
    %ageHeaderToBin = ();
    my $prefix = "[..";
    foreach my $days (@cutpoints) {
        my $header = $prefix . $days . "] days";
        push(@ageGroupHeader, $header);
        $prefix = "(" . $days . ",";
    }
    push(@ageGroupHeader, "(" . $cutpoints[-1] . "..) days");
    my $bin = 0;
    foreach my $header (@ageGroupHeader) {
        $ageHeaderToBin{$header} = $bin;
        ++$bin;
    }
}

sub findAgeBin
{
    my $age = shift;
    defined($age) or die("undefined age");
    my $bin;
    for ($bin = 0; $bin <= $#cutpoints; $bin++) {
        last
            if ($age <= $cutpoints[$bin]);
    }
    return $bin;
}

sub new
{
    my ($class, $type, $name, $is_absolute_dir) = @_;
    my $self = {};
    bless $self, $class;

    # 'type' expected to be one of 'file', 'directory', 'top'
    $self->{type} = $type;
    $self->{name} = $name;
    defined($name) || $type eq 'top' or
        die("SummaryInfo name should be defined, except at top-level");
    if ($type eq "file") {
        $self->{fileDetails} = undef;    # will point to SourceFile struct
    } else {
        $self->{sources}     = {};
        $self->{is_absolute} = $is_absolute_dir
            if $type eq 'directory';
    }
    $self->{parent} = undef;

    _initCounts($self, 'line');
    _initCounts($self, 'function');
    _initCounts($self, 'branch');

    for my $prefix ("", "branch_", "function_") {
        my $g = $prefix . "age";
        $self->{$g} = [];
        foreach my $i (0 .. $#cutpoints + 1) {
            $self->{$g}->[$i] = {
                        _LB => ($i == 0) ? undef : $cutpoints[$i - 1],
                        _UB => ($i == $#cutpoints + 1) ? undef : $cutpoints[$i],
                        _INDEX => $i
            };
            _initCounts($self->{$g}->[$i]);
        }
    }

    $self->{owners} = {};    # developer -> hash of TLA->count - lineCov data
    $self->{owners_branch} = {};   # developer -> hash of TLA->count - branchCov

    return $self;
}

# deserialization:  copy the coverage portion of the undumped data
sub copyGuts
{
    my ($self, $that) = @_;
    while (my ($k, $v) = each(%$that)) {
        next if $k =~ /(type|name|sources|parent)/;
        $self->{$k} = $v;
    }
}

sub name
{
    my $self = shift;
    return $self->{name};
}

sub type
{
    my $self = shift;
    return $self->{type};
}

sub is_directory
{
    my ($self, $is_absolute) = @_;
    return (
        $self->type() eq 'directory' ?
            ((defined($is_absolute) && $is_absolute) ? $self->{is_absolute} : 1)
        :
            0);
}

sub parent
{
    my $self = shift;
    return $self->{parent};
}

sub setParent
{
    my ($self, $parent) = @_;
    die("expected parent dir")
        unless (ref($parent) eq "SummaryInfo" &&
                'directory' eq $parent->type());
    $self->{parent} = $parent;
}

sub sources
{
    my $self = shift;
    return keys(%{$self->{sources}});
}

sub fileDetails
{
    my ($self, $data) = @_;
    $self->type() eq 'file' or die("source details only available for file");
    !(defined($data) && defined($self->{fileDetails})) or
        die("attempt to set details in initialized struct");
    !defined($data) || ref($data) eq 'SourceFile' or
        die("unexpected data arg " . ref($data));
    $self->{fileDetails} = $data
        if defined($data);
    return $self->{fileDetails};
}

sub get_sorted_keys
{
    # sort_type in ($SORT_FILE, $SORT_LINE, $SORT_FUNC, $SORT_BRANCH)
    my ($self, $sort_type, $include_dirs) = @_;

    my $sources = $self->{sources};

    my @keys = $self->sources();
    my @l;
    foreach my $k (@keys) {
        my $data = $sources->{$k};
        next
            if ($data->type() eq 'directory' &&
                (!defined($include_dirs) ||
                 0 == $include_dirs));
        push(@l, $k);
    }
    if ($sort_type == $SORT_FILE) {
        # alphabetic
        return sort(@l);
    }
    my $covtype;
    if ($sort_type == $SORT_LINE) {
        # Sort by number of instrumented lines without coverage
        $covtype = 'line';
    } elsif ($sort_type == $SORT_FUNC) {
        # Sort by number of instrumented functions without coverage
        $covtype = 'function';
    } else {
        die("unexpected sort type $sort_type")
            unless ($sort_type == $SORT_BRANCH);
        # Sort by number of instrumented branches without coverage
        $covtype = 'branch';
    }

    if ($main::opt_missed) {
        # sort by directory first then secondary key
        return
            sort({
                     my $da = $sources->{$a};
                     my $db = $sources->{$b};
                     # directories then files if list includes both
                     $da->type() cmp $db->type() or
                         $db->get_missed($covtype)
                         <=> $da->get_missed($covtype) or
                         # sort alphabetically in case of tie
                         $da->name() cmp $db->name()
            } @l);
    } else {
        return
            sort({
                     my $da = $sources->{$a};
                     my $db = $sources->{$b};
                     $da->type() cmp $db->type() or
                         $da->get_rate($covtype) <=> $db->get_rate($covtype) or
                         $da->name() cmp $db->name()
            } @l);
    }
}

sub get_source
{
    my ($self, $name) = @_;
    return
        exists($self->{sources}->{$name}) ? $self->{sources}->{$name} : undef;
}

sub get
{
    my ($self, $key, $type) = @_;
    $type = 'line'
        if !defined($type);

    my $hash = $self->{$type};
    if ($key eq "total") {
        return $hash->{found};
    } elsif ($key eq "missed") {
        my $missed = 0;
        foreach my $k ('UBC', 'UNC', 'UIC', 'LBC') {
            $missed += $hash->{$k}
                if (exists($hash->{$k}));
        }
        return $missed;
    } else {
        die("ERROR:  unexpected 'get' key $key")
            unless exists($hash->{$key});
        return $hash->{$key};
    }
}

# Return a relative value for the specified found&hit values
# which is used for sorting the corresponding entries in a
# file list.
#
sub get_rate
{
    my ($self, $covtype) = @_;

    my $hash  = $self->{$covtype};
    my $found = $hash->{found};
    my $hit   = $hash->{hit};

    if ($found == 0) {
        #return 100;
        return 1000;
    }
    #return (100.0 * $hit) / $found;
    return int($hit * 1000 / $found) * 10 + 2 - (1 / $found);
}

sub get_missed
{
    my ($self, $covtype) = @_;

    my $hash  = $self->{$covtype};
    my $found = $hash->{found};
    my $hit   = $hash->{hit};

    return $found - $hit;
}

sub contains_owner
{
    my ($self, $owner) = @_;
    return exists($self->{owners}->{$owner});
}

sub owners
{
    # return possibly empty list of line owners in this file
    #   - filter only those which have 'missed' lines
    my ($self, $showAll, $covType) = @_;

    (!defined($covType) || $covType eq 'line' || $covType eq 'branch') or
        die("unsupported coverage type '$covType'");

    my $hash = $self->{owners}
        if (!defined($covType) || $covType eq 'line');
    $hash = $self->{owners_branch}
        if ($covType eq 'branch');

    return keys(%$hash)
        if $showAll;

    my @rtn;
    OWNER:
    foreach my $name (keys(%$hash)) {
        my $h = $hash->{$name};
        foreach my $tla ('UNC', 'UBC', 'UIC', 'LBC') {
            if (exists($h->{$tla})) {
                die("unexpected 0 (zero) value for $tla of $name in $self->path()"
                ) if (0 == $h->{$tla});
                push(@rtn, $name);
                next OWNER;
            }
        }
    }
    return @rtn;
}

sub owner_tlaCount
{
    my ($self, $name, $tla, $covType) = @_;
    die("$name not found in owner data for $self->path()")
        unless exists($self->{owners}->{$name});

    return 0    # not supported, yet
        if defined($covType) && $covType eq 'function';

    my $ownerKey = 'owners';
    $ownerKey .= "_$covType"
        if defined($covType) && $covType ne 'line';
    my $hash = $self->{$ownerKey}->{$name};
    return $hash->{$tla}
        if (exists($hash->{$tla}));

    if ($tla eq "total" ||
        $tla eq "found") {
        my $total = 0;
        foreach my $k (keys(%$hash)) {
            # count only code that can be hit (ie., not excluded)
            $total += $hash->{$k}
                if ('EUB' ne $k &&
                    'ECB' ne $k);
        }
        return $total;
    } elsif ($tla eq "hit") {
        my $hit = 0;
        foreach my $k ('CBC', 'GBC', 'GIC', 'GNC') {
            $hit += $hash->{$k}
                if (exists($hash->{$k}));
        }
        return $hit;
    } elsif ($tla eq "missed") {
        my $missed = 0;
        foreach my $k ('UBC', 'UNC', 'UIC', 'LBC') {
            $missed += $hash->{$k}
                if (exists($hash->{$k}));
        }
        return $tla eq "missed" ? $missed : -$missed;
    }
    die("unexpected TLA $tla")
        unless exists($tlaLocation{$tla});
    return 0;
}

sub hasOwnerInfo
{
    my $self = shift;

    return %{$self->{owners}} ? 1 : 0;
}

sub hasDateInfo
{
    my $self = shift;
    # we get date- and owner information at the same time from the
    #  annotation-script - so, if we have owner info, then we have date info too.
    return scalar(%{$self->{owners}});
}

sub findOwnerList
{
    # return [ [owner, lineCovData, branchCovData, functionCov]] for each owner
    #  where lineCovData = [missedCount, totalCount]
    #        branchCovData = [missed, total] or undef if not enabled
    #        functionCov = [missed, total] or undef if not enabled
    #   - sorted in decending order number of missed lines
    my ($self, $all) = @_;

    my @owners;
    foreach my $owner (keys(%{$self->{owners}})) {
        my $lineMissed = $self->owner_tlaCount($owner, 'missed');
        my $branchMissed =
            $main::br_coverage ?
            $self->owner_tlaCount($owner, 'missed', 'branch') :
            0;
        my $funcMissed =
            $main::func_coverage ?
            $self->owner_tlaCount($owner, 'missed', 'function') :
            0;
        # filter owners who have unexercised code, if requested

        if ($all ||
            (0 != $lineMissed || 0 != $branchMissed || 0 != $funcMissed)) {
            my $lineCb   = OwnerDetailCallback->new($self, $owner, 'line');
            my $branchCb = OwnerDetailCallback->new($self, $owner, 'branch');
            my $functionCb =
                OwnerDetailCallback->new($self, $owner, 'function');
            my $lineTotal = $self->owner_tlaCount($owner, 'found');
            my $branchTotal =
                $main::br_coverage ?
                $self->owner_tlaCount($owner, 'found', 'branch') :
                0;
            my $funcTotal =
                $main::func_coverage ?
                $self->owner_tlaCount($owner, 'found', 'function') :
                0;
            push(@owners,
                 [$owner,
                  [$lineMissed, $lineTotal, $lineCb],
                  [$branchMissed, $branchTotal, $branchCb],
                  [$funcMissed, $funcTotal, $functionCb]
                 ]);
        }
    }
    @owners = sort({
                       $b->[1]->[0]     <=> $a->[1]->[0] ||    # missed
                           $b->[1]->[1] <=> $a->[1]->[1] ||    # then total
                           $a->[0] cmp $b->[0]
    } @owners);    # then by name
    return scalar(@owners) ? \@owners : undef;
}

sub append
{
    my ($self, $record) = @_;

    # keep track of the records that get merged into me..
    defined($record->{name}) or
        die("attempt to anonymous SummaryInfo record");
    !exists($self->{sources}->{$record->{name}}) or
        die("duplicate merge record " . $record->{name});
    $self->{sources}->{$record->{name}} = $record;

    die($record->name() . " already has parent " . $record->parent()->name())
        if (defined($record->parent()) && $record->{parent} != $self);
    $record->{parent} = $self
        if !defined($record->parent());

    foreach my $group ("line", "function", "branch") {
        foreach my $key (keys %{$self->{$group}}) {
            $self->{$group}->{$key} += $record->{$group}->{$key};
        }
    }

    # there will be no date info if we didn't also collect owner data
    #   merge the date- and owner data, if if we aren't going to display it
    #   (In future, probably want to serialize the data for future processing)
    if (%{$record->{owners}}) {
        foreach my $covType ("line", "branch", "function") {
            for (my $bin = 0; $bin <= $#ageGroupHeader; ++$bin) {
                foreach my $key (keys %{$self->{$covType}}) {
                    # duplicate line-coverage buckets
                    my $ageval = $self->age_sample($bin);
                    if ($covType eq 'line') {
                        $self->lineCovCount($key, "age", $ageval,
                                   $record->lineCovCount($key, "age", $ageval));
                    } elsif ($covType eq 'branch') {
                        $self->branchCovCount($key, "age", $ageval,
                                 $record->branchCovCount($key, "age", $ageval));
                    } else {
                        $self->functionCovCount($key, 'age', $ageval,
                               $record->functionCovCount($key, "age", $ageval));
                    }
                }
            }
            my $ownerKey = "owners";
            $ownerKey .= "_$covType" if ('line' ne $covType);

            foreach my $name (keys(%{$record->{$ownerKey}})) {
                my $yours = $record->{$ownerKey}->{$name};
                if (!exists($self->{$ownerKey}->{$name})) {
                    $self->{$ownerKey}->{$name} = {};
                }
                my $mine = $self->{$ownerKey}->{$name};

                foreach my $tla (keys(%$yours)) {
                    my $count = exists($mine->{$tla}) ? $mine->{$tla} : 0;
                    $count += $yours->{$tla};
                    $mine->{$tla} = $count;
                }
            }
        }
    }
    return $self;
}

sub age_sample
{
    my $self = shift;
    my $i    = shift;
    my $bin  = $self->{age}->[$i];
    return ($i < $#ageGroupHeader) ? $bin->{_UB} : ($bin->{_LB} + 1);
}

sub lineCovCount
{
    my $self  = shift;
    my $key   = shift;
    my $group = shift;
    my $age   = ($group eq "age") ? shift : undef;
    my $delta = defined($_[0]) ? shift : 0;

    if ($key eq 'total') {
        $key = 'found';
    } elsif ($key eq 'missed') {
        my $found = $self->lineCovCount('found', $group, $age);
        my $hit   = $self->lineCovCount('hit', $group, $age);
        return $found - $hit;
    }

    $key = 'found' if $key eq 'total';
    if ($group eq "age") {
        my $a   = $self->{age};
        my $bin = SummaryInfo::findAgeBin($age);
        exists($a->[$bin]) && exists($a->[$bin]->{$key}) or
            die("unexpected key '$key' for bin '$bin'");
        $a->[$bin]->{$key} += $delta;
        return $a->[$bin]->{$key};
    }

    defined($self->{$group}) or
        die("SummaryInfo::value: unrecognized group $group\n");
    defined($self->{$group}->{$key}) or
        die("SummaryInfo::value: unrecognized key $key\n");

    $self->{$group}->{$key} += $delta;
    return $self->{$group}->{$key};
}

sub branchCovCount
{
    my $self  = shift;
    my $key   = shift;
    my $group = shift;
    my $age   = ($group eq "age") ? shift : undef;
    my $delta = defined($_[0]) ? shift : 0;

    if ($key eq 'total') {
        $key = 'found';
    } elsif ($key eq 'missed') {
        my $found = $self->branchCovCount('found', $group, $age);
        my $hit   = $self->branchCovCount('hit', $group, $age);
        return $found - $hit;
    }

    my $g = "branch_" . $group;
    if ($group eq "age") {
        my $a   = $self->{$g};
        my $bin = SummaryInfo::findAgeBin($age);
        unless (exists($a->[$bin]) && exists($a->[$bin]->{$key})) {
            lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                                      "unexpected key '$key' for bin '$bin'");
            return;
        }
        $a->[$bin]->{$key} += $delta;
        return $a->[$bin]->{$key};
    }
    defined($self->{$g}) or
        die("SummaryInfo::value: unrecognized branch group $group\n");
    defined($self->{$g}->{$key}) or
        die("SummaryInfo::value: unrecognized branch key $key\n");

    $self->{$g}->{$key} += $delta;
    return $self->{$g}->{$key};
}

sub functionCovCount
{
    my $self  = shift;
    my $key   = shift;
    my $group = shift;
    my $age   = ($group eq "age") ? shift : undef;
    my $delta = defined($_[0]) ? shift : 0;

    if ($key eq 'total') {
        $key = 'found';
    } elsif ($key eq 'missed') {
        my $found = $self->functionCovCount('found', $group, $age);
        my $hit   = $self->functionCovCount('hit', $group, $age);
        return $found - $hit;
    }

    my $g = "function_" . $group;
    if ($group eq "age") {
        my $a   = $self->{$g};
        my $bin = SummaryInfo::findAgeBin($age);
        unless (exists($a->[$bin]) && exists($a->[$bin]->{$key})) {
            lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                                      "unexpected key '$key' for bin '$bin'");
            return;
        }
        $a->[$bin]->{$key} += $delta;
        return $a->[$bin]->{$key};
    }
    defined($self->{$g}) or
        die("SummaryInfo::value: unrecognized function group $group\n");
    defined($self->{$g}->{$key}) or
        die("SummaryInfo::value: unrecognized function key $key\n");

    $self->{$g}->{$key} += $delta;
    return $self->{$g}->{$key};
}

sub l_found
{
    my $self  = shift;
    my $delta = defined($_[0]) ? shift : 0;

    $self->{line}->{found} += $delta;
    return $self->{line}->{found};
}

sub l_hit
{
    my $self  = shift;
    my $delta = defined($_[0]) ? shift : 0;

    $self->{line}->{hit} += $delta;
    return $self->{line}->{hit};
}

sub f_found
{
    my $self  = shift;
    my $delta = defined($_[0]) ? shift : 0;

    $self->{function}->{found} += $delta;
    return $self->{function}->{found};
}

sub f_hit
{
    my $self  = shift;
    my $delta = defined($_[0]) ? shift : 0;

    $self->{function}->{hit} += $delta;
    return $self->{function}->{hit};
}

sub b_found
{
    my $self  = shift;
    my $delta = defined($_[0]) ? shift : 0;

    $self->{branch}->{found} += $delta;
    return $self->{branch}->{found};
}

sub b_hit
{
    my $self  = shift;
    my $delta = defined($_[0]) ? shift : 0;

    $self->{branch}->{hit} += $delta;
    return $self->{branch}->{hit};
}

sub checkCoverageCriteria
{
    my $self = shift;
    return unless defined $coverageCriteriaScript;

    my %data;
    foreach my $t ('line', 'function', 'branch') {
        my $d = $self->{$t};
        foreach my $k (keys %$d) {
            # $k will be 'hit', 'found' or one of the TLAs
            my $count = $d->{$k};
            next if $count == 0;
            if (exists $data{$t}) {
                $data{$t}->{$k} = $count;
            } else {
                $data{$t} = {$k => $count};
            }
        }
    }
    my $json = JsonSupport::encode(\%data);          # imported from lcovutil.pm
    my @cmd  = split(' ', $coverageCriteriaScript);
    splice(@cmd, 1, 0,
           "'" . ($self->type() eq 'top' ? 'top' : $self->name()) . "'",
           $self->type(), "'" . $json . "'");
    # command:  script name (top|dir|file) jsonString args..
    my $cmd = join(' ', @cmd);
    lcovutil::info(1, "criteria: '$cmd'");
    if (open(HANDLE, "-|", $cmd)) {
        my @msg;
        while (my $line = <HANDLE>) {
            chomp $line;
            $line =~ s/\r//g;    # remove CR from line-end
            next if '' eq $line;
            push(@msg, $line);
        }
        close(HANDLE);
        my $status = $? >> 8;
        my $name   = $self->type() eq 'top' ? "" : $self->name();
        $coverageCriteria{$name} = [$self->type(), $status, \@msg]
            if (0 != $status ||
                0 != scalar(@msg));
        $coverageCriteriaStatus = $status
            if $status != 0;
    } else {
        print("Error: 'open(-| $cmd)' failed: \"$!\"\n");
    }
}

package OwnerDetailCallback;
# somewhat of a hack...I want a class which has a callback 'get'
#  that matches the SummaryInfo::get method - but returns owner-specific
#  information
sub new
{
    my ($class, $summary, $owner, $covType) = @_;
    $covType = 'line' unless defined($covType);

    my $self = [$summary, $owner, $covType];
    bless $self, $class;
    return $self;
}

sub label
{
    my $self = shift;
    return $self->owner();
}

sub cb_type
{
    my $self = shift;
    return 'owner';
}

sub get
{
    my ($self, $key, $type) = @_;

    my ($summary, $owner, $covType) = @$self;

    die("unexpected type $type")
        unless (!defined($type) || ($type eq $covType));

    return $summary->owner_tlaCount($owner, $key, $covType);
}

sub owner
{
    my $self = shift;
    return $self->[1];
}

sub covType
{
    my $self = shift;
    return $self->[2];
}

package DateDetailCallback;
# as above:  callback class to return date-specific TLA counts
sub new
{
    my ($class, $summary, $age, $covType) = @_;
    $covType = 'line' unless defined($covType);

    my $self = [$summary, $age, $covType, SummaryInfo::findAgeBin($age)];
    bless $self, $class;
    return $self;
}

sub get
{
    my ($self, $key, $type) = @_;

    my ($summary, $age, $covType) = @$self;

    die("unexpected type $type")
        unless (!defined($type) || ($type eq $covType));

    return $summary->lineCovCount($key, 'age', $age)
        if $covType eq 'line';

    return $summary->functionCovCount($key, 'age', $age)
        if $covType eq 'function';

    die('$covType coverage not yet implemented') if $covType ne 'branch';

    return $summary->branchCovCount($key, 'age', $age);
}

sub label
{
    my $self = shift;
    return $self->age();
}

sub cb_type
{
    my $self = shift;
    return 'date';
}

sub age
{
    my $self = shift;
    return $self->[1];
}

sub bin
{
    my $self = shift;
    return $self->[3];
}

sub covType
{
    my $self = shift;
    return $self->[2];
}

package FileOrDirectoryCallback;
# callback class used by 'write_file_table' to retrieve count of the
# various coverpoint categories in the file or directory (i.e., total
# number).
# Other callbacks classes are used to retrieve per-owner counts, etc.

sub new
{
    # dirSummary: SummaryInfo object
    my ($class, $path, $summary) = @_;

    my $self = [$path, $summary];

    bless $self, $class;
    return $self;
}

# page_link is HTML reference to file table page next level down -
#   for top-level page:  link to directory-level page
#   for directory-level page:  link to source file details
sub page_link
{
    my $self      = shift;
    my $data      = $self->summary();
    my $page_link = $self->name();
    if ($data->type() eq 'file') {
        if ($main::no_sourceview) {
            return "";
        }
        $page_link .= ".gcov";
        $page_link .= ".frameset"
            if ($main::frames);
    } else {
        $page_link =~ s/^\///;
        $page_link .= "/index";
    }
    return $page_link . '.' . $main::html_ext;
}

sub data
{
    my $self = shift;
    # ($found, $hit, $fn_found, $fn_hit, $br_found, $br_hit, $page_link,
    #  $fileSummary, $fileDetails)

    my $summary = $self->summary();
    my @rtn;
    foreach my $type ('line', 'function', 'branch') {
        my $hash = $summary->{$type};
        push(@rtn, $hash->{found}, $hash->{hit});
    }
    my $link       = $self->page_link();
    my $sourceFile = $summary->fileDetails()
        if 'file' eq $summary->type();
    push(@rtn, $link, $summary, $sourceFile);
    return @rtn;
}

sub secondaryElementFileData
{
    my ($self, $name) = @_;
    my $summary    = $self->summary();
    my $sourceFile = $summary->fileDetails()
        if 'file' eq $summary->type();
    return [$summary->name(), $sourceFile, $self->page_link()];
}

sub name
{
    my $self = shift;
    return $self->[0];
}

sub summary
{
    # return undef or SummaryInfo object
    my $self = shift;
    return $self->[1];
}

sub findOwnerList
{
    my ($self, $all) = @_;
    # return [ [owner, lineCovData, branchCovData]] for each owner
    #  where lineCovData = [missedCount, totalCount, callback]
    #        branchCovData = [missed, total, callback] or undef if not enabled
    #   - sorted in decending order number of missed lines
    return $self->summary()->findOwnerList($all);
}

sub dateDetailCallback
{
    # callback to compute count in particular date bin
    my ($self, $ageval, $covtype) = @_;
    $covtype eq 'line' || $covtype eq 'branch' || $covtype eq 'function' or
        die("'$covtype' type not supported");

    return DateDetailCallback->new($self->summary(), $ageval, $covtype);
}

sub ownerDetailCallback
{
    # callback to compute count in particular owner bin
    my ($self, $owner, $covtype) = @_;
    $covtype eq 'line' || $covtype eq 'branch' or
        die("'$covtype' type not supported");

    return OwnerDetailCallback->new($self->summary(), $owner, $covtype);
}

sub totalCallback
{
    my ($self, $covtype) = @_;
    # callback to compute total elements of 'covtype' in each TLA
    if ('line' eq $covtype) {
        return $self->summary();
    } else {
        return CovTypeSummaryCallback->new($self->summary(), $covtype);
    }
}

package FileOrDirectoryOwnerCallback;
# callback class used by 'write_file_table' to retrieve owner-
#  specific coverage numbers (for all entries in the directory)

sub new
{
    my ($class, $owner, $dirSummary) = @_;

    my $self = [$owner, $dirSummary];
    bless $self, $class;
    return $self;
}

sub name
{
    my $self = shift;
    return $self->[0];
}

sub data
{
    my $self = shift;

    my $lineCb   = OwnerDetailCallback->new($self->[1], $self->[0], 'line');
    my $found    = $lineCb->get('found');
    my $hit      = $lineCb->get('hit');
    my $branchCb = OwnerDetailCallback->new($self->[1], $self->[0], 'branch');
    my $fn_found = 0;
    # ($found, $hit, $fn_found, $fn_hit, $br_found, $br_hit, $page_link,
    #  $fileSummary, $fileDetails)
    # this is the 'totals' callback for this owner - so there is no
    #  associated file or summary info.  Pass undef.
    return ($lineCb->get('found'), $lineCb->get('hit'),
            0, 0,    # fn_found, fn_hit
            $branchCb->get('found'), $branchCb->get('hit'));
}

sub totalCallback
{
    # callback to compute total 'covtype' elements in each TLA
    my ($self, $covtype) = @_;
    die("$covtype not supported by OwnerDetail callback")
        unless ($covtype eq 'line' || $covtype eq 'branch');

    return OwnerDetailCallback->new($self->[1], $self->name(), $covtype);
}

sub findFileList
{
    my ($self, $all) = @_;

    # return [ [filename, lineCovData, branchCovData]] for each file
    #   such that this owner has at least 1 line.
    #  where lineCovData = [missedCount, totalCount, OwnerDetailCallback]
    #        branchCovData = [missed, total, dateDetailCallback]
    #                         or undef if not enabled
    #   - sorted in decending order number of missed lines
    my $dirSummary = $self->[1];
    my $owner      = $self->[0];
    my @files;
    foreach my $file ($dirSummary->sources()) {
        my $source = $dirSummary->get_source($file);
        next unless $source->contains_owner($owner);

        my $lineCb   = OwnerDetailCallback->new($source, $owner, 'line');
        my $brCb     = OwnerDetailCallback->new($source, $owner, 'branch');
        my $funcCb   = OwnerDetailCallback->new($source, $owner, 'function');
        my $total    = $lineCb->get('found');
        my $br_total = $main::br_coverage ? $brCb->get('found') : 0;
        my $fn_total = $main::func_coverage ? $funcCb->get('found') : 0;
        next if (0 == $total &&
                 0 == $br_total &&
                 0 == $fn_total);
        my $missed    = $lineCb->get('missed');
        my $br_missed = $main::br_coverage ? $brCb->get('missed') : 0;
        my $fn_missed = $main::func_coverage ? $funcCb->get('missed') : 0;

        if ($all ||
            0 != $missed    ||
            0 != $br_missed ||
            0 != $fn_missed) {

            push(@files,
                 [$file,
                  [$missed, $total, $lineCb],
                  [$br_missed, $br_total, $brCb],
                  [$fn_missed, $fn_total, $funcCb]
                 ]);
        }
    }
    return @files;
}

sub secondaryElementFileData
{
    my ($self, $name) = @_;
    my $dirSummary    = $self->[1];
    my $file          = File::Basename::basename($name);
    my $sourceSummary = $dirSummary->get_source($name);

    my $page_link;
    if ($sourceSummary->is_directory()) {
        $page_link = $name . "/index-bin_owner." . $main::html_ext;
    } elsif ($main::no_sourceview) {
        $page_link = "";
    } else {
        $name      = $file;
        $page_link = $name . ".gcov.";
        $page_link .= "frameset."
            if $main::frames;
        $page_link .= $main::html_ext;
    }
    # pass owner in callback data
    my $sourceFile = $sourceSummary->fileDetails()
        if 'file' eq $sourceSummary->type();
    return [$name, $sourceFile, $page_link, $self->[0]];
}

package FileOrDirectoryDateCallback;
# callback class used by 'write_file_table' to retrieve date-
#  specific coverage numbers (for all entries in the directory)

sub new
{
    my ($class, $bin, $dirSummary) = @_;

    my $self = [$bin, $dirSummary->age_sample($bin), $dirSummary];
    bless $self, $class;
    return $self;
}

sub name
{
    my $self = shift;
    return $SummaryInfo::ageGroupHeader[$self->[0]];
}

sub data
{
    my $self = shift;

    my @rtn;
    foreach my $covType ('line', 'function', 'branch') {
        my $cb = DateDetailCallback->new($self->[2], $self->[1], $covType);
        push(@rtn, $cb->get('found'), $cb->get('hit'));
    }
    # ($found, $hit, $fn_found, $fn_hit, $br_found, $br_hit, $page_link,
    #  $fileSummary, $fileDetails)
    # this is the top-level 'total' callback - so no associated file or
    # summary info
    return @rtn;
}

sub totalCallback
{
    # callback to compute total elements of 'covtype' in each TLA
    my ($self, $covtype) = @_;
    return DateDetailCallback->new($self->[2], $self->[1], $covtype);
}

sub findFileList
{
    my ($self, $all) = @_;

    # return [ [filename, lineCovData, branchCovData]] for each file
    #   such that this owner has at least 1 line.
    #  where lineCovData = [missedCount, totalCount, OwnerDetailCallback]
    #        branchCovData = [missed, total, dateDetailCallback]
    #                         or undef if not enabled
    #   - sorted in decending order number of missed lines
    my $dirSummary = $self->[2];
    my $ageval     = $self->[1];
    my @files;
    foreach my $file ($dirSummary->sources()) {
        my $source = $dirSummary->get_source($file);

        my $lineCb   = DateDetailCallback->new($source, $ageval, 'line');
        my $brCb     = DateDetailCallback->new($source, $ageval, 'branch');
        my $funcCb   = DateDetailCallback->new($source, $ageval, 'function');
        my $total    = $lineCb->get('found');
        my $br_total = $main::br_coverage ? $brCb->get('found') : 0;
        my $fn_total = $main::func_coverage ? $funcCb->get('found') : 0;
        next if (0 == $total &&
                 0 == $br_total &&
                 0 == $fn_total);

        my $missed    = $lineCb->get('missed');
        my $br_missed = $main::br_coverage ? $brCb->get('missed') : 0;
        my $fn_missed = $main::func_coverage ? $funcCb->get('missed') : 0;
        if ($all ||
            0 != $missed    ||
            0 != $br_missed ||
            0 != $fn_missed) {
            push(@files,
                 [$file,
                  [$missed, $total, $lineCb],
                  [$br_missed, $br_total, $brCb],
                  [$fn_missed, $fn_total, $funcCb]
                 ]);
        }
    }
    return @files;
}

sub secondaryElementFileData
{
    my ($self, $name) = @_;
    my $dirSummary    = $self->[2];
    my $file          = File::Basename::basename($name);
    my $sourceSummary = $dirSummary->get_source($name);

    my $page_link;
    if ($sourceSummary->is_directory()) {
        $page_link = $name . "/index-bin_date." . $main::html_ext;
    } elsif ($main::no_sourceview) {
        $page_link = "";
    } else {
        $name      = $file;
        $page_link = $name . ".gcov.";
        $page_link .= "frameset."
            if $main::frames;
        $page_link .= $main::html_ext;
    }
    # pass bin index in callback data
    my $sourceFile = $sourceSummary->fileDetails()
        if 'file' eq $sourceSummary->type();
    return [$name, $sourceFile, $page_link, $self->[0]];
}

package CovTypeSummaryCallback;
# callback class to return total branches in each TLA categroy
sub new
{
    my ($class, $summary, $covType) = @_;
    defined($summary) or
        die("no summary");
    die("$covType not supported yet")
        unless ($covType eq 'line' ||
                $covType eq 'branch' ||
                $covType eq 'function');
    my $self = [$summary, $covType];
    bless $self, $class;
    return $self;
}

sub get
{
    my ($self, $key) = @_;

    return $self->[0]->get($key, $self->[1]);
}

sub owner
{
    my $self = shift;
    die("CovTypeSummaryCallback::owner not supported for " . $self->[1])
        unless ($self->[1] eq 'branch');
    return $self->[0]->owner();
}

sub age
{
    my $self = shift;
    return $self->[0]->age();
}

sub bin
{
    my $self = shift;
    return $self->[0]->bin();
}

sub covType
{
    my $self = shift;
    return $self->[1];
}

package PrintCallback;
# maintain some callback data from one line to the next

sub new
{
    my ($class, $sourceFileStruct, $lineCovInfo) = @_;
    my $self = {};
    bless $self, $class;

    $self->{fileInfo}         = $sourceFileStruct;
    $self->{lineData}         = $lineCovInfo;
    $self->{currentTLA}       = "";
    $self->{_owner}           = "";
    $self->{_age}             = "";
    $self->{_nextOwnerHeader} = {};   # next header line for corresponding owner
    $self->{_nextDateHeader} = {}; # next header line for corresponding date bin
    $self->{_lineNo}         = undef;
    return $self;
}

sub sourceDetail
{
    my $self = shift;
    return $self->{fileInfo};
}

sub lineData
{
    my $self = shift;
    return $self->{lineData};
}

sub lineNo
{
    my ($self, $lineNo) = @_;
    $self->{_lineNo} = $lineNo
        if defined($lineNo);
    return $self->{_lineNo};
}

sub tla
{
    my $self   = shift;
    my $newTLA = shift;
    my $lineNo = shift;
    # NOTE:  'undef' TLA means that this line is not code (it is a comment,
    #    blank line, opening brace or something).
    # We return 'same' as previous line' in that case so the category
    #   block can be larger (e.g., 1 CBC line, a 2 line comment, then 3 more
    #   lines) can get just one label (first line).
    # This reduces visual clutter.
    # Note that the 'block finding' code has to do the same thing (else the
    #   HTML links won't be generated correctly)
    if (defined($newTLA) &&
        $newTLA ne $self->{currentTLA}) {
        $self->{currentTLA} = $newTLA;
        return $newTLA;
    }
    return "   ";    # same TLA as previous line.
}

sub age
{
    my $self   = shift;
    my $newval = shift;
    my $lineNo = shift;
    if (defined($newval) && $newval ne $self->{_age}) {
        $self->{_age} = $newval;
        return $newval;
    }
    return " " x 5;    # same age as previous line.
}

sub owner
{
    my $self   = shift;
    my $newval = shift;
    my $lineNo = shift;
    if (defined($newval) && $newval ne $self->{_owner}) {
        $self->{_owner} = $newval;
        return $newval;
    }
    return " " x 20;    # same age as previous line.
}

sub current
{
    my ($self, $key) = @_;

    if ($key eq 'tla') {
        return $self->{currentTLA};
    } elsif ($key eq 'owner') {
        return $self->{_owner};
    } elsif ($key eq 'age') {
        return $self->{_age};
    } else {
        ($key eq 'dateBucket') or
            die("unexpected key $key");
        return SummaryInfo::findAgeBin($self->{_age});
    }
}

sub nextOwner
{
    my ($self, $owner, $tla, $value) = @_;
    my $map = $self->{_nextOwnerHeader};

    my $key = $tla . ' ' . $owner;
    if (defined($value)) {
        $map->{$key} = $value;
        return $value;
    }
    return exists($map->{$key}) ? $map->{$key} : undef;
}

sub nextDate
{
    my ($self, $date, $tla, $value) = @_;
    my $map = $self->{_nextDateHeader};
    my $key = $tla . ' ' . $date;
    if (defined($value)) {
        $map->{$key} = $value;
        return $value;
    }
    return $map->{$key};
}

package ReadBaselineSource;

sub new
{
    my ($class, $diffData) = @_;

    my $self = [$diffData, ReadCurrentSource->new()];
    bless $self, $class;
    return $self;
}

sub open
{
    my ($self, $filename) = @_;

    $self->[1]->open($filename, "baseline ");
    $self->[1]->notEmpty() or
        die("unable to read baseline '$filename'");
    $self->[2] = $filename;
}

sub close
{
    my $self = shift;
    $self->[1]->close();
}

sub notEmpty
{
    my $self = shift;
    return $self->[1]->notEmpty();
}

sub isOutOfRange
{
    my $self = shift;
    return $self->[1]->isOutOfRange(@_);
}

sub isExcluded
{
    my $self = shift;
    return $self->[1]->isExcluded(@_);
}

sub filename
{
    return $_[0]->[2];
}

sub getLine
{
    my ($self, $line) = @_;
    my ($map, $reader, $filename) = @$self;
    my $type = $map->type($filename, "old", $line);
    if ($type ne 'delete') {
        my $currLine = $map->lookup($filename, "old", $line);
        return $reader->getLine($currLine);
    } else {
        # deleted line...we don't really care what it looked like
        #  return empty - so the line gets treated as not conditional
        return undef;
    }
}

sub isCharacter
{
    my $self = shift;
    return $self->[1]->isCharacter(@_);
}

sub isCloseBrace
{
    my ($self, $line) = @_;
    my ($map, $reader, $filename) = @$self;
    my $type = $map->type($filename, "old", $line);
    if ($type ne 'delete') {
        my $currLine = $map->lookup($filename, "old", $line);
        return $reader->isCloseBrace($currLine);
    } else {
        return 0;
    }
}

sub containsConditional
{
    my ($self, $line) = @_;
    my ($map, $reader, $filename) = @$self;
    my $type = $map->type($filename, "old", $line);
    if ($type ne 'delete') {
        my $currLine = $map->lookup($filename, "old", $line);
        return $reader->containsConditional($currLine);
    } else {
        return 1;    # we don't know - so just go with what gcov said
    }
}

sub suppressCloseBrace
{
    my $self = shift;
    return $self->[1]->isCharacter(@_);
}

sub isBlank
{
    my $self = shift;
    return $self->[1]->isBlank(@_);
}

package LineData;

sub new
{
    my ($class, $type) = @_;
    # [ type, lineNo_base, lineNo_current,
    #   bucket, base_count, curr_count    <- line coverage count data
    #   base_branch, curr_branch, differential_branch ] <- branch coverage count data
    # $type in ('insert', 'equal', 'delete')
    my $self = [$type, undef, undef,
                ['UNK', 0, 0],    # line coverage data
                [],               # branch coverge data
                []
    ];    # function coverage
    bless $self, $class;
    return $self;
}

sub tla
{
    my ($self, $tla) = @_;
    my $linecov = $self->[3];
    $linecov->[0] = $tla
        if defined($tla);
    return $linecov->[0];
}

sub type
{
    my $self = shift;
    return $self->[0];
}

sub lineNo
{
    my ($self, $which, $lineNo) = @_;
    my $loc;
    if ($which eq "current") {
        $loc = 2;
    } else {
        die("unknown key $which - should be 'base' or 'current'")
            unless $which eq "base";
        $loc = 1;
    }
    die("inconsistent $which line location $loc: " .
        $self->[$loc] . " -> $lineNo")
        if (defined($lineNo) &&
            defined($self->[$loc]) &&
            $self->[$loc] != $lineNo);

    $self->[$loc] = $lineNo
        if defined($lineNo);
    return $self->[$loc];
}

sub in_base
{
    # @return true or false:  is this object present in the baseline?
    my $self = shift;
    return defined($self->[1]);
}

sub in_curr
{
    # @return true or false:  is this object present in the current version?
    my $self = shift;
    return defined($self->[2]);
}

sub base_count
{
    # return line hit count in baseline
    my ($self, $inc) = @_;
    die("non-zero count but not in base")
        if (defined($inc) && !defined($self->[1]));
    my $linecov = $self->[3];
    $linecov->[1] += $inc
        if defined($inc);

    return $linecov->[1];
}

sub curr_count
{
    # return line hit count in current
    my ($self, $inc) = @_;
    die("non-zero count but not in current")
        if (defined($inc) && !defined($self->[2]));
    my $linecov = $self->[3];
    $linecov->[2] += $inc
        if defined($inc);

    return $linecov->[2];
}

sub _mergeBranchData
{
    my ($self, $loc, $branchData) = @_;
    my $branch = $self->[4];
    if (defined($branch->[$loc])) {

        my $current = $branch->[$loc];
        foreach my $branchId ($current->blocks()) {
            $branchData->hasBlock($branchId) or
                die("missing branch ID $branchId for line " . $self->lineNo());
            my $c = $current->getBlock($branchId);
            my $d = $branchData->getBlock($branchId);
            scalar(@$c) == scalar(@$d) or
                die("inconsistent data for branch ID $branchId for line " .
                    $self->lineNo());
            for (my $i = scalar(@$c) - 1; $i >= 0; --$i) {
                my $br = $d->[$i];
                $c->[$i]->merge($br);
            }
        }
    } else {
        $branch->[$loc] = Storable::dclone($branchData);
    }
}

sub baseline_branch
{
    my ($self, $branchData) = @_;
    die("has baseline branch data but not in baseline")
        if (defined($branchData) && !defined($self->[1]));
    if (defined($branchData)) {
        $self->_mergeBranchData(0, $branchData);
    }
    my $branch = $self->[4];
    return $branch->[0];
}

sub current_branch
{
    my ($self, $branchData) = @_;
    die("has current branch data but not in current")
        if (defined($branchData) && !defined($self->[2]));
    if (defined($branchData)) {
        $self->_mergeBranchData(1, $branchData);
    }
    my $branch = $self->[4];
    return $branch->[1];
}

sub differential_branch
{
    my ($self, $differential) = @_;
    my $branch = $self->[4];
    if (defined($differential)) {
        $branch->[2] = $differential;
    }
    return $branch->[2];
}

sub _mergeFunctionData
{
    my ($self, $loc, $functionData) = @_;
    my $function = $self->[5];
    if (defined($function->[$loc])) {
        my $current = $function->[$loc];
        $current->merge($functionData);
    } else {
        $function->[$loc] = Storable::dclone($functionData);
    }
}

sub baseline_function
{
    my ($self, $functionData) = @_;
    die("has baseline function data but not in baseline")
        if (defined($functionData) && !defined($self->[1]));
    if (defined($functionData)) {
        $self->_mergeFunctionData(0, $functionData);
    }
    my $function = $self->[5];
    return $function->[0];
}

sub current_function
{
    my ($self, $functionData) = @_;
    die("has current function data but not in current")
        if (defined($functionData) && !defined($self->[2]));
    if (defined($functionData)) {
        $self->_mergeFunctionData(1, $functionData);
    }
    my $function = $self->[5];
    return $function->[1];
}

sub differential_function
{
    my ($self, $differential) = @_;
    my $function = $self->[5];
    if (defined($differential)) {
        $function->[2] = $differential;
    }
    return $function->[2];
}

# structure holding coverage data for a particular file:
#  - associated with a line line number:
#     - line coverage
#     - branch coverage
#  - function coverage (not directly associated with line number
package FileCoverageInfo;

sub new
{
    my ($class, $filename, $base_data, $current_data, $linemap, $verbose) = @_;

    # [hash of lineNumber -> LineData struct, optional FunctionMap]
    my $self = [[$base_data->version(), $current_data->version()], {}];
    bless $self, $class;

    $linemap->show_map($filename)
        if ((defined($verbose) && $verbose) ||
            (defined($lcovutil::verbose) && $lcovutil::verbose));

    # line coverage categorization includes date- and owner- bins in
    #   the vanilla case when there is no baseline.
    $self->_categorizeLineCov($filename, $base_data, $current_data,
                              $linemap, $verbose);
    $self->_categorizeBranchCov($filename, $base_data, $current_data,
                                $linemap, $verbose)
        if ($main::br_coverage);
    $self->_categorizeFunctionCov($filename, $base_data, $current_data,
                                  $linemap, $verbose)
        if ($main::func_coverage);
    return $self;
}

sub version
{
    my ($self, $which) = @_;
    return $which eq 'current' ? $self->[0]->[1] : $self->[0]->[0];
}

sub lineMap
{
    my $self = shift;
    return $self->[1];
}

sub functionMap
{
    # simply a map of funtion leader name -> differeential FunctionEntry
    my $self = shift;
    return (scalar(@$self) > 2) ? $self->[2] : undef;
}

sub line
{
    my ($self, $lineNo) = @_;
    my $lineMap = $self->lineMap();
    return exists($lineMap->{$lineNo}) ? $lineMap->{$lineNo} : undef;
}

sub recategorizeTlaAsBaseline
{
    # intended use:  this file appears to have been added to the "coverage"
    # suite - but the file itself is old/has been around for a long time.
    #   - by default, we will see this as "Included Code"
    #      - which means that 'un-exercised' code will be "UIC"
    #   - but:  non-zero UIC will fail our Jenkins coverage ratchet.
    # As a workaround:  treat this file as if the baseline data was the same
    # as 'current' - so code will be categorized as "CBC/UBC" - which will not
    # trigger the coverage criteria.
    my $self    = shift;
    my $lineMap = $self->lineMap();
    my %remap = ('UIC' => 'UBC',
                 'GIC' => 'CBC');

    foreach my $line (keys %$lineMap) {
        my $data = $lineMap->{$line};
        die("unexpected $line 'in_base'") if $data->in_base();

        my $lineTla = $data->tla();
        if (exists($remap{$lineTla})) {
            # don't remap GNC, UNC, etc
            $data->tla($remap{$lineTla});
        }

        # branch coverage...
        if ($main::br_coverage && defined($data->differential_branch())) {
            my $br = $data->differential_branch();

            foreach my $branchId ($br->blocks()) {
                my $diff = $br->getBlock($branchId);
                foreach my $b (@$diff) {
                    my $tla = $b->[1];
                    if (exists($remap{$tla})) {
                        $b->[1] = $remap{$tla};
                    }
                }
            }
        }    # if branch data

        # function coverage..
        if ($main::func_coverage && defined($data->differential_function())) {
            my $func = $data->differential_function();
            my $hit  = $func->hit();
            my $tla  = $hit->[1];
            if (exists($remap{$tla})) {
                $hit->[1] = $remap{$tla};
            }

            my $aliases = $func->aliases();
            foreach my $alias (keys %$aliases) {
                my $data = $aliases->{$alias};
                my $tla  = $data->[1];
                if (exists($remap{$tla})) {
                    $data->[1] = $remap{$tla};
                }
            }
        }
    }    # if function data
}

sub _categorize
{
    my ($baseCount, $currCount) = @_;
    my $tla;
    if (0 == $baseCount) {
        $tla = (0 == $currCount) ? "UBC" : "GBC";
    } elsif (0 == $currCount) {
        $tla = "LBC";
    } else {
        $tla = "CBC";
    }
    return $tla;
}

# categorize line coverage numbers
sub _categorizeLineCov
{
    my ($self, $filename, $base_data, $current_data, $linemap, $verbose) = @_;
    my $lineDataMap = $self->lineMap();

    my $lineCovBase    = $base_data->test();
    my $lineCovCurrent = $current_data->test();

    foreach my $testcase ($lineCovCurrent->keylist()) {
        my $testcount = $lineCovCurrent->value($testcase);
        foreach my $line ($testcount->keylist()) {
            my $type = $linemap->type($filename, "new", $line);
            $type ne 'delete' or
                die(
                "'current' line $filename:$line should not be marked 'delete'");
            # next if ($type ne "delete");
            my $linedata;
            if (!exists($lineDataMap->{$line})) {
                $linedata = LineData->new($type);
                $lineDataMap->{$line} = $linedata;
            } else {
                $linedata = $lineDataMap->{$line};
            }
            my $val = $testcount->value($line);
            $linedata->lineNo("current", $line);
            $linedata->curr_count($val);
        }
    }
    foreach my $testcase ($lineCovBase->keylist()) {
        my $testcount = $lineCovBase->value($testcase);
        foreach my $bline ($testcount->keylist()) {
            my $cline = $linemap->lookup($filename, "old", $bline);
            my $type  = $linemap->type($filename, "old", $bline);
            my $linedata;
            if ($type ne "delete") {
                if (!defined($lineDataMap->{$cline})) {
                    $lineDataMap->{$cline} = LineData->new($type);
                }
                $linedata = $lineDataMap->{$cline};
            } else {
                # nothing walks the keylist so a prefix is sufficient to distiguish
                # records that should be summarized but not displayed
                my $dline = "<<<" . $bline;
                if (!defined($lineDataMap->{$dline})) {
                    $lineDataMap->{$dline} = LineData->new($type);
                }
                $linedata = $lineDataMap->{$dline};
            }
            my $val = $testcount->value($bline);
            $linedata->lineNo("base", $bline);
            $linedata->base_count($val);
        }
    }

    foreach my $line (keys %$lineDataMap) {
        my $linedata = $lineDataMap->{$line};
        my $tla;
        if ($linedata->type() eq "insert") {
            $tla = ($linedata->curr_count() > 0) ? "GNC" : "UNC";
        } elsif ($linedata->type() eq "delete") {
            $tla = ($linedata->base_count() > 0) ? "DCB" : "DUB";
        } else {
            $linedata->type() eq "equal" or
                die(
                "FileCoverageInfo:: deleted segment line=$line file=$filename");

            if ($linedata->in_base() && $linedata->in_curr()) {
                $tla =
                    _categorize($linedata->base_count(), $linedata->curr_count);
            } elsif ($linedata->in_base()) {
                $tla = ($linedata->base_count() > 0) ? "ECB" : "EUB";
                $linedata->tla($tla);
            } else {
                $linedata->in_curr() or
                    die(
                    "FileCoverageInfo:: non-executed line line=$line file=$filename"
                    );

                $tla = ($linedata->curr_count() > 0) ? "GIC" : "UIC";
            }
        }
        $linedata->tla($tla);
    }
}

# categorize branch coverage numbers
sub _categorizeBranchCov
{
    my ($self, $filename, $base_data, $current_data, $linemap, $verbose) = @_;
    my $lineDataMap = $self->lineMap();

    my $branchCovBase    = $base_data->testbr();
    my $branchCovCurrent = $current_data->testbr();

    my %branchCovLines;
    # look through the 'current' data, to find all the branch data
    foreach my $testcase ($branchCovCurrent->keylist()) {
        my $branchCurrent = $branchCovCurrent->value($testcase);
        foreach my $line ($branchCurrent->keylist()) {
            my $type = $linemap->type($filename, "new", $line);
            lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                 "'current' line $filename:$line should not be marked 'delete'")
                if $type eq 'delete';
            #next if $type eq 'delete';

            $branchCovLines{$line} = 1;
            my $data;
            if (!exists($lineDataMap->{$line})) {
                $data = LineData->new($type);
                $lineDataMap->{$line} = $data;
                # we expect the associated line to also have line coverage data
                lcovutil::ignorable_error($ERROR_UNKNOWN_CATEGORY,
                     "line $line of $filename has branchcov but no linecov data"
                );
            } else {
                $data = $lineDataMap->{$line};
            }
            # we expect that the line number matches...
            $data->lineNo("current", $line);
            # append this branch data for the line
            my $currBranchData = $branchCurrent->value($line);
            $data->current_branch($currBranchData);
        }    # foreach line in this testcase's branch data
    }    #foreach current testcase

    # now look through the baseline to find matching data
    foreach my $testcase ($branchCovBase->keylist()) {
        my $branchBaseline = $branchCovBase->value($testcase);
        foreach my $base_line ($branchBaseline->keylist()) {
            my $curr_line = $linemap->lookup($filename, "old", $base_line);
            my $type      = $linemap->type($filename, "old", $base_line);
            my $data;
            if ($type ne 'delete') {
                $branchCovLines{$curr_line} = 1;
                if (!exists($lineDataMap->{$curr_line})) {
                    $data = LineData->new($type);
                    $lineDataMap->{$curr_line} = $data;
                } else {
                    $data = $lineDataMap->{$curr_line};
                }
            } else {
                # the line has been deleted...just record the data
                my $deleteKey = "<<<" . $base_line;
                $branchCovLines{$deleteKey} = 1;
                if (!exists($lineDataMap->{$deleteKey})) {
                    $data = LineData->new($type);
                    $lineDataMap->{$deleteKey} = $data;
                } else {
                    $data = $lineDataMap->{$deleteKey};
                }
            }
            $data->lineNo("base", $base_line);
            my $baseBranchData = $branchBaseline->value($base_line);
            $data->baseline_branch($baseBranchData);
        }    # foreach line in baseline data for this test..
    }    # foreach baseline testcase

    # now go through all the branch data for each line, and categorize everything
    foreach my $line (keys(%branchCovLines)) {
        my $data        = $self->lineMap()->{$line};
        my $type        = $data->type();
        my $curr        = $data->current_branch();
        my $base        = $data->baseline_branch();
        my $categorized = BranchEntry->new($line);
        $data->differential_branch($categorized);
        # handle case that baseline and/or current do not contain branch data
        my @currBlocks = defined($curr) ? $curr->blocks() : ();
        my @baseBlocks = defined($base) ? $base->blocks() : ();

        if ($type eq 'insert') {
            lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                "baseline branch data should not be defined for inserted line $filename:$line"
            ) if defined($base);
            foreach my $branchId (@currBlocks) {
                my $block = $categorized->addBlock($branchId);
                foreach my $br (@{$curr->getBlock($branchId)}) {
                    my $count = $br->count();
                    my $tla   = (0 == $count) ? 'UNC' : 'GNC';
                    push(@$block, [$br, $tla]);
                }
            }
        } elsif ($type eq 'delete') {
            lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                "current branch data should not be defined for deleted line $filename:$line"
            ) if defined($curr);
            foreach my $branchId (@baseBlocks) {
                my $block = $categorized->addBlock($branchId);
                foreach my $br (@{$base->getBlock($branchId)}) {
                    my $count = $br->count();
                    my $tla   = (0 == $count) ? 'DUB' : 'DCB';
                    push(@$block, [$br, $tla]);
                }
            }
        } else {
            lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                     "unexpected branch coverage type $type at $filename:$line")
                if $type ne 'equal';

            # branch might or might not be in both baseline and current
            foreach my $branchId (@baseBlocks) {
                my $b          = $base->getBlock($branchId);
                my $branchData = $categorized->addBlock($branchId);
                if (defined($curr) &&
                    $curr->hasBlock($branchId)) {
                    my $c = $curr->getBlock($branchId);

                    my $num_base = scalar(@$b);
                    my $num_curr = scalar(@$c);
                    my $max = $num_base > $num_curr ? $num_base : $num_curr;
                    my $tla;
                    for (my $i = 0; $i < $max; ++$i) {
                        if ($i < $num_base &&
                            $i < $num_curr) {
                            my $base_br = $b->[$i];
                            my $curr_br = $c->[$i];
                            $tla =
                                _categorize($base_br->count(),
                                            $curr_br->count());
                            push(@$branchData, [$curr_br, $tla]);
                        } elsif ($i < $num_base) {
                            my $base_br = $b->[$i];
                            $tla = (0 == $base_br->count()) ? 'EUB' : 'ECB';
                            push(@$branchData, [$base_br, $tla]);
                        } else {
                            my $curr_br = $c->[$i];
                            $tla = (0 == $curr_br->count()) ? 'UIC' : 'GIC';
                            push(@$branchData, [$curr_br, $tla]);
                        }
                    }
                } else {
                    # branch not found in current...
                    foreach my $base_br (@$b) {
                        my $tla = (0 == $base_br->count()) ? 'EUB' : 'ECB';
                        push(@$branchData, [$base_br, $tla]);
                    }
                }
            }
            # now check for branches that are in current but not in baseline...
            foreach my $branchId (@currBlocks) {
                next
                    if defined($base) &&
                    $base->hasBlock($branchId);    # already processed
                my $c          = $curr->getBlock($branchId);
                my $branchData = $categorized->addBlock($branchId);
                foreach my $curr_br (@$c) {
                    my $tla = (0 == $curr_br->count()) ? 'UIC' : 'GIC';
                    push(@$branchData, [$curr_br, $tla]);
                }
            }    # foreach branchId in current that isn't in base
        }
    }
}

sub _categorizeFunctionCov
{
    my ($self, $filename, $base_data, $current_data, $linemap, $verbose) = @_;
    !defined($self->functionMap()) or die("map should not be defined yet");
    my $differentialMap = {};
    push(@$self, $differentialMap);
    my $lineDataMap = $self->lineMap();

    my $funcBase    = $base_data->testfnc();
    my $funcCurrent = $current_data->testfnc();

    my %funcCovLines;
    foreach my $testcase ($funcCurrent->keylist()) {
        my $test = $funcCurrent->value($testcase);
        foreach my $key ($test->keylist()) {
            my $func = $test->findKey($key);
            my $line = $func->line();
            my $type = $linemap->type($filename, 'new', $line);
            $funcCovLines{$line} = 1;
            lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                 "'current' line $filename:$line should not be marked 'delete'")
                if $type eq 'delete';

            my $data;
            if (!exists($lineDataMap->{$line})) {
                $data = LineData->new($type);
                $lineDataMap->{$line} = $data;
            } else {
                $data = $lineDataMap->{$line};
                lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                            "type mismatch " .
                                $data->type() . " -> $type for $filename:$line")
                    unless $data->type() eq $type;
            }
            # we expect that the line number matches...
            $data->lineNo("current", $line);
            # function data for the line
            $data->current_function($func);
        }
    }    # foreach current testcase
         # now look through the baseline to find matching data
    foreach my $testcase ($funcBase->keylist()) {
        my $test = $funcBase->value($testcase);
        foreach my $key ($test->keylist()) {
            my $func      = $test->findKey($key);
            my $line      = $func->line();
            my $type      = $linemap->type($filename, 'old', $line);
            my $curr_line = $linemap->lookup($filename, "old", $line);
            my $data;
            if ($type ne 'delete') {
                $funcCovLines{$curr_line} = 1;

                if (!exists($lineDataMap->{$curr_line})) {
                    $data = LineData->new($type);
                    $lineDataMap->{$curr_line} = $data;
                } else {
                    $data = $lineDataMap->{$curr_line};
                }
            } else {
                # the line has been deleted...just record the data
                my $deleteKey = "<<<" . $line;
                $funcCovLines{$deleteKey} = 1;
                if (!exists($lineDataMap->{$deleteKey})) {
                    $data = LineData->new($type);
                    $lineDataMap->{$deleteKey} = $data;
                } else {
                    $data = $lineDataMap->{$deleteKey};
                }
            }
            die("inconsistent 'base' line number")
                if (defined($data->lineNo("base")) &&
                    $data->lineNo("base") != $line);
            $data->lineNo("base", $line);
            $data->baseline_function($func);
        }    # foreach line in baseline data for this test..
    }    # foreach baseline testcase

    # now go through function data for each line and categorize...
    foreach my $line (keys %funcCovLines) {
        my $data        = $lineDataMap->{$line};
        my $type        = $data->type();
        my $curr        = $data->current_function();
        my $base        = $data->baseline_function();
        my $name        = defined($curr) ? $curr->name() : $base->name();
        my $categorized = FunctionEntry->new($name, $filename, $line);
        $differentialMap->{$name} = $categorized;

        $data->differential_function($categorized);

        if (!defined($base)) {
            # either this line was inserted or the line hasn't changed but
            #   wasn't recognized as a function before (e.g., unused template)
            lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                "unexpected undef baseline function data for deleted $filename:$line"
            ) if $type eq 'delete';
            my $hit = $curr->hit();
            my $tla = ((0 == $hit) ? ($type eq 'insert' ? 'UNC' : 'UIC') :
                           ($type eq 'insert' ? 'GNC' : 'GIC'));
            $categorized->setCountDifferential([$hit, $tla]);
            my $aliases = $curr->aliases();
            foreach my $alias (keys %$aliases) {
                $hit = $aliases->{$alias};
                $tla = ((0 == $hit) ? ($type eq 'insert' ? 'UNC' : 'UIC') :
                            ($type eq 'insert' ? 'GNC' : 'GIC'));
                $categorized->addAliasDifferential($alias, [$hit, $tla]);
            }
        } elsif (!defined($curr)) {
            lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                "unexpected undef current function data for inserted $filename:$line"
            ) if $type eq 'insert';
            my $hit = $base->hit();
            my $tla = ((0 == $hit) ? ($type eq 'delete' ? 'DUB' : 'EUB') :
                           ($type eq 'delete' ? 'DCB' : 'ECB'));
            $categorized->setCountDifferential([$hit, $tla]);
            my $aliases = $base->aliases();
            foreach my $alias (keys %$aliases) {
                $hit = $aliases->{$alias};
                $tla = ((0 == $hit) ? ($type eq 'delete' ? 'DUB' : 'EUB') :
                            ($type eq 'delete' ? 'DCB' : 'ECB'));
                $categorized->addAliasDifferential($alias, [$hit, $tla]);
            }
        } else {
            lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                   "unexpected function coverage type $type ar $filename:$line")
                if $type ne 'equal';
            my $tla = _categorize($base->hit(), $curr->hit());
            $categorized->setCountDifferential([$curr->hit(), $tla]);
            # particular alias may be in both versions
            my $base_aliases = $base->aliases();
            my $curr_aliases = $curr->aliases();
            foreach my $alias (keys %$base_aliases) {
                my $hit = $base_aliases->{$alias};

                my $tla;
                if (exists($curr_aliases->{$alias})) {
                    my $hitCurr = $curr_aliases->{$alias};
                    $tla = _categorize($hit, $hitCurr);
                    $hit = $hitCurr;
                } else {
                    $tla = (0 == $hit) ? 'EUB' : 'ECB';
                }
                $categorized->addAliasDifferential($alias, [$hit, $tla]);
            }
            # now look for aliases that are in current but not in baseline
            foreach my $alias (keys %$curr_aliases) {
                next if exists($base_aliases->{$alias});

                my $hit = $curr_aliases->{$alias};
                my $tla = (0 == $hit) ? "UIC" : "GIC";
                $categorized->addAliasDifferential($alias, [$hit, $tla]);
            }
        }

        if ('UNK' eq $data->tla()) {
            # there is a function here - but no line - manufacture some data
            my $d = $categorized->hit();
            my ($hit, $funcTla) = @$d;
            $data->tla($funcTla);
            if (defined($base) &&
                $data->in_base()) {
                $data->base_count($base->hit());
            }
            if (defined($curr) &&
                $data->in_curr()) {
                $data->curr_count($hit);
            }
        }
    }
}

package LineMap;

sub new
{
    my $class = shift;
    my $self  = {};
    bless $self, $class;
    $self->{linemap}      = {};
    $self->{filemap}      = {};
    $self->{diffFileName} = undef;
    # keep track of line number where file entry is found in diff file
    #   - use line number in error messages.
    $self->{defLocation} =
        [{}, {}];            # element 0: old filename -> line number where this
                             #             entry starts
                             # element 1: new filename -> line numbern
    $self->{unchanged} = {}; # file is identical in baseline and current
    return $self;
}

sub load
{
    my $self = shift;
    my $path = shift;
    $self->_read_udiff($path);

    return $self;
}

sub lookup
{
    my $self = shift;
    my $file = shift;
    my $vers = shift;
    my $line = shift;

    if (!defined($self->{linemap}->{$file})) {
        #mapping is identity when no diff was read
        return $line;
    }

    my @candidates =
        grep { $_->{$vers}->{start} < $line } @{$self->{linemap}->{$file}};
    my $chunk = pop @candidates;

    my $alt = ($vers eq "old") ? "new" : "old";

    if ($line > $chunk->{$vers}->{end}) {
        return ($chunk->{$alt}->{end} + ($line - $chunk->{$vers}->{end}));
    }
    return ($chunk->{$alt}->{start} + ($line - $chunk->{$vers}->{start}));
}

sub type
{
    my $self = shift;
    my $file = shift;
    my $vers = shift;
    my $line = shift;

    if (!defined($self->{linemap}->{$file})) {
        #mapping is identity when no diff was read
        if (defined($main::base_filename) &&
            defined($main::show_tla)) {
            return "equal";    # categories will be "GIC", "UIC"
        } else {
            return "insert";    # categories will be "GNC", "UNC"
        }
    }

    if (!defined($self->{filemap}->{$file})) {
        #mapping with no filemap when baseline file was deleted
        return "delete";
    }

    # ->{start} equal $line only if beginning of range or omitted in ->{type}
    my @candidates =
        grep { $_->{$vers}->{start} <= $line } @{$self->{linemap}->{$file}};
    my $chunk = pop @candidates;
    my $prev  = pop @candidates;
    while (defined($prev) &&
           $line >= $prev->{$vers}->{start} &&
           $line <= $prev->{$vers}->{end}) {
        $chunk = $prev;
        $prev  = pop @candidates;
    }
    if (!defined($chunk)) {
        warn "LineMap::type(): got undef chunk at $file, $vers, $line\n";
        return "undef chunk";
    }
    if (!defined($chunk->{type})) {
        warn "LineMap::type(): got undef type at $file, $vers, $line\n";
        return "undef type";
    }
    return $chunk->{type};
}

sub baseline_file_name
{
    # file may have been moved between baseline and current...
    my $self         = shift;
    my $current_name = shift;

    if (exists($self->{filemap}->{$current_name})) {
        return $self->{filemap}->{$current_name};
    }
    return $current_name;
}

sub files
{
    my $self = shift;
    return keys(%{$self->{filemap}});
}

sub dump_map
{
    my $self = shift;

    foreach my $file (keys %{$self->{filemap}}) {
        my $currfile =
            defined($self->{filemap}->{$file}) ? $self->{filemap}->{$file} :
            "[deleted]";
        printf("In $file (was: $currfile):\n");
        foreach my $chunk (@{$self->{linemap}->{$file}}) {
            printf("  %6s\t[%d:%d]\t[%d:%d]\n",
                   $chunk->{type}, $chunk->{old}->{start},
                   $chunk->{old}->{end}, $chunk->{new}->{start},
                   $chunk->{new}->{end});
        }
    }
    return $self;
}

sub check_path_consistency
{
    # check that paths which appear in diff also appear in baseline or current
    #  .info files - if not, then there is likely a path consistency issue
    # $baseline and $current are both TraceFile structs -
    # return 0 if inconsistency found

    my ($self, $baseline, $current) = @_;
    (ref($baseline) eq 'TraceFile' && ref($current) eq 'TraceFile') or
        die("wrong arg types");

    my %diffMap;
    my %diffBaseMap;
    foreach my $f ($self->files()) {
        $diffMap{$f} = 0;
        my $b = File::Basename::basename($f);
        $diffBaseMap{$b} = [[], {}]
            unless exists($diffBaseMap{$b});
        push(@{$diffBaseMap{$b}->[0]}, $f);
    }
    foreach my $f (keys %{$self->{unchanged}}) {
        # unchanged in baseline and current
        $diffMap{$f} = 3;
    }
    my %missed;
    foreach my $curr ($current->files()) {
        my $b = File::Basename::basename($curr);
        if (exists($diffMap{$curr})) {
            $diffMap{$curr} |= 1;    # used in current
            $diffBaseMap{$b}->[1]->{$curr} = 0
                unless exists($diffBaseMap{$b}->[1]->{$curr});
            ++$diffBaseMap{$b}->[1]->{$curr};
        } else {
            $missed{$curr} = 1;      # in current but not in diff
        }
    }
    foreach my $base ($baseline->files()) {
        my $b = File::Basename::basename($base);
        if (exists($diffMap{$base})) {
            $diffMap{$base} |= 2;    # used in baseline
            $diffBaseMap{$b}->[1]->{$base} = 0
                unless exists($diffBaseMap{$b}->[1]->{$base});
            ++$diffBaseMap{$b}->[1]->{$base};
        } else {
            # in baseline but not in diff
            if (exists($missed{$base})) {
                $missed{$base} |= 2;
            } else {
                $missed{$base} = 2;
            }
        }
    }
    my $ok = 1;
    foreach my $f (sort keys(%missed)) {
        my $b = File::Basename::basename($f);
        if (exists($diffBaseMap{$b})) {
            # this basename is in the diff file and didn't match any other
            #   trace filename entry (i.e., same filename in more than one
            #   source code directory) - then warn about possible pathname issue
            my ($diffFiles, $sourceFiles) = @{$diffBaseMap{$b}};
            # find the files which appear in the 'diff' list which have the
            #   same basename and were not matched - those might be candidates
            my @unused;
            for my $d (@$diffFiles) {
                # my $location = $self->{diffFileName} . ':' . $self->{defLocation}->[1]->{$d};
                push(@unused, $d)
                    unless exists($sourceFiles->{$d});
            }
            if (scalar(@unused)) {
                my $type;

                # my $baseData = $baseline->data($f);
                # my $baseLocation = join(":", ${$baseData->location()});
                # my $currData = $current->data($f);
                # my $currLocation = join(":", ${$currData->location()});

                if (2 == $missed{$f}) {
                    $type = "baseline";
                } elsif (1 == $missed{$f}) {
                    $type = "current";
                } else {
                    $type = "both baseline and current";
                }
                my $single = 1 == scalar(@unused);
                # @todo could print line numbers in baseline, current .info files and
                #   in diff file ..
                warn("source file '$f' (in $type .info file" .
                     ($missed{$f} == 3 ? "s" : "") .
                     ") has same basename as 'diff' " .
                     ($single ? 'entry ' : "entries:\n\t") . "'" .
                     join("'\n\t", @unused) . "' - but a different path." .
                     ($single ? "  " : "\n\t") .
                     "Possible pathname mismatch?");
                if ($main::elide_path_mismatch &&
                    $missed{$f} == 3 &&
                    $single) {
                    $self->{filemap}->{$f} = $f;
                    $self->{linemap}->{$f} = $self->{linemap}->{$unused[0]};
                } else {
                    $ok = 0;
                }
            }
        }
    }
    return $ok;
}

sub show_map
{
    my $self = shift;
    my $file = shift;

    if (!defined($self->{filemap}->{$file})) {
        return $self;
    }
    my $currfile =
        defined($self->{filemap}->{$file}) ? $self->{filemap}->{$file} :
        "[deleted]";
    printf("In $file (was: $currfile):\n");
    foreach my $chunk (@{$self->{linemap}->{$file}}) {
        printf("  %6s\t[%d:%d]\t[%d:%d]\n",
               $chunk->{type}, $chunk->{old}->{start},
               $chunk->{old}->{end}, $chunk->{new}->{start},
               $chunk->{new}->{end});
    }
    return $self;
}

sub strip_directories
{
    my $path = shift;
    return $path;
}

sub _read_udiff
{
    my $self      = shift;
    my $diff_file = shift;    # Name of diff file
    my $line;                 # Contents of current line
    my $file_old;             # Name of old file in diff section
    my $file_new;             # Name of new file in diff section
    my $filename;             # Name of common filename of diff section

    # Check if file exists and is readable
    stat($diff_file);
    if (!(-r _)) {
        die("ERROR: cannot read udiff file $diff_file!\n");
    }

    $self->{diffFileName} = $diff_file;

    my $diffFile = InOutFile->in($diff_file);
    my $diffHdl  = $diffFile->hdl();

    my $chunk;
    my $old_block = 0;
    my $new_block = 0;
    # would like to use Regexp::Common::time - but module not installed
    #my $time = $RE{time}{iso};
    my $time =
        '[1-9]{1}[0-9]{3}\-[0-9]{2}\-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]*)?( .[0-9]+)?';
    # Parse diff file line by line
    while (<$diffHdl>) {
        chomp($_);
        s/\r//g;
        $line = $_;

        # the 'diff' new/old file name line may be followed by a timestamp
        #   If so, remove it so our regexp matches more easily.
        # p4 and git diff outputs do not have the timestamp
        if ($line =~ /^[-+=]{3} \S.*(\s+$time)$/) {
            $line =~ s/\Q$1\E$//;
        }
        foreach ($line) {
            # Filename of unchanged file:
            # === <filename>
            /^=== (.+)$/ && do    # note: filename may contain whitespace
            {
                if ($filename) {
                    push(@{$self->{linemap}->{$filename}}, $chunk);
                    undef $filename;
                }
                my $file = File::Spec->rel2abs($1, $main::cwd);
                $file = lcovutil::strip_directories($file, $main::strip);
                die("$file already in linemap - marked unchangd")
                    if (exists($self->{unchanged}->{$file}));
                warn("$file duplicate 'unchanged' entry found")
                    if (exists($self->{linemap}->{$file}));

                $self->{unchanged}->{$file} = 1;

                last;
            };

            # Filename of old file:
            # --- <filename>
            /^--- (.+)$/ && do {
                if ($filename) {
                    push(@{$self->{linemap}->{$filename}}, $chunk);
                    undef $filename;
                }
                $file_old = File::Spec->rel2abs($1, $main::cwd);
                $file_old =
                    lcovutil::strip_directories($file_old, $main::strip);
                $self->{defLocation}->[0]->{$file_old} = $.;
                #$in_block = 0;
                last;
            };
            # Filename of new file:
            # +++ <filename>
            /^\+\+\+ (.+)$/ && do {
                # Add last file to resulting hash
                $file_new = File::Spec->rel2abs($1, $main::cwd);
                $file_new =
                    lcovutil::strip_directories($file_new, $main::strip);
                $filename = ($file_new ne "/dev/null") ? $file_new : undef;
                if ($filename) {
                    $self->{linemap}->{$filename} = [];
                }
                if ($file_new ne "/dev/null") {
                    $self->{filemap}->{$file_new} = $file_old;
                    # keep track of location where this file was found
                    $self->{defLocation}->[1]->{$file_new} = $.;
                }
                $chunk                 = {};
                $chunk->{from}         = {};
                $chunk->{to}           = {};
                $chunk->{type}         = "equal";
                $chunk->{old}->{start} = 1;
                $chunk->{old}->{end}   = 1;
                $chunk->{new}->{start} = 1;
                $chunk->{new}->{end}   = 1;

                last;
            };
            # Start of diff block:
            # @@ -old_start,old_num, +new_start,new_num @@
            /^\@\@\s+-(\d+),(\d+)\s+\+(\d+),(\d+)\s+\@\@.*$/ && do {
                if ($1 > ($chunk->{old}->{end})) {
                    # old start skips "equal" lines
                    if ($chunk->{type} ne "equal") {
                        if ($filename) {
                            push(@{$self->{linemap}->{$filename}}, $chunk);
                        }
                        my $oldchunk = $chunk;
                        $chunk                 = {};
                        $chunk->{from}         = {};
                        $chunk->{to}           = {};
                        $chunk->{type}         = "equal";
                        $chunk->{old}->{start} = $oldchunk->{old}->{end} + 1;
                        $chunk->{old}->{end}   = $oldchunk->{old}->{end} + 1;
                        $chunk->{new}->{start} = $oldchunk->{new}->{end} + 1;
                        $chunk->{new}->{end}   = $oldchunk->{new}->{end} + 1;
                    }
                    $chunk->{type} = "equal";
                    $chunk->{old}->{end} =
                        $1 - 1;    # will increment on content lines
                    $chunk->{new}->{end} = $3 - 1;
                } else {
                    $chunk->{old}->{end} =
                        $1 - 1;    # will increment on content lines
                    $chunk->{new}->{end} = $3 - 1;
                }
                $old_block = $2;
                $new_block = $4;
                #printf "equal [%d:%d] [%d:%d]\n", $l[0], $l[1], $l[2], $l[3];
                last;
            };
            # Unchanged line
            # <line starts with blank>
            /^ / && do {
                if ($old_block == 0 && $new_block == 0) {
                    last;
                }
                if ($chunk->{type} ne "equal") {
                    if ($filename) {
                        push(@{$self->{linemap}->{$filename}}, $chunk);
                    }
                    my $oldchunk = $chunk;
                    $chunk                 = {};
                    $chunk->{from}         = {};
                    $chunk->{to}           = {};
                    $chunk->{type}         = "equal";
                    $chunk->{old}->{start} = $oldchunk->{old}->{end} + 1;
                    $chunk->{old}->{end}   = $oldchunk->{old}->{end} + 1;
                    $chunk->{new}->{start} = $oldchunk->{new}->{end} + 1;
                    $chunk->{new}->{end}   = $oldchunk->{new}->{end} + 1;
                } else {
                    $chunk->{new}->{end} += 1;
                    $chunk->{old}->{end} += 1;
                }
                last;
            };
            # Line as seen in old file
            # <line starts with '-'>
            /^-/ && do {
                if ($old_block == 0 && $new_block == 0) {
                    last;
                }
                if ($chunk->{type} ne "delete") {
                    if ($filename) {
                        push(@{$self->{linemap}->{$filename}}, $chunk);
                    }
                    my $oldchunk = $chunk;
                    $chunk                 = {};
                    $chunk->{from}         = {};
                    $chunk->{to}           = {};
                    $chunk->{type}         = "delete";
                    $chunk->{old}->{start} = $oldchunk->{old}->{end} + 1;
                    $chunk->{old}->{end}   = $oldchunk->{old}->{end} + 1;
                    $chunk->{new}->{start} = $oldchunk->{new}->{end};
                    $chunk->{new}->{end}   = $oldchunk->{new}->{end};
                } else {
                    #$chunk->{old}->{start} += 1;
                    $chunk->{old}->{end} += 1;
                }
                last;
            };
            # Line as seen in new file
            # <line starts with '+'>
            /^\+/ && do {
                if ($old_block == 0 && $new_block == 0) {
                    last;
                }
                if ($chunk->{type} ne "insert") {
                    if ($filename) {
                        push(@{$self->{linemap}->{$filename}}, $chunk);
                    }
                    my $oldchunk = $chunk;
                    $chunk                 = {};
                    $chunk->{from}         = {};
                    $chunk->{to}           = {};
                    $chunk->{type}         = "insert";
                    $chunk->{old}->{start} = $oldchunk->{old}->{end};
                    $chunk->{old}->{end}   = $oldchunk->{old}->{end};
                    $chunk->{new}->{start} = $oldchunk->{new}->{end} + 1;
                    $chunk->{new}->{end}   = $oldchunk->{new}->{end} + 1;
                } else {
                    #$chunk->{new}->{start} += 1;
                    $chunk->{new}->{end} += 1;
                }
                last;
            };
            # Empty line
            /^$/ && do {
                if ($old_block == 0 && $new_block == 0) {
                    last;
                }
                if ($chunk->{type} ne "equal") {
                    if ($filename) {
                        push(@{$self->{linemap}->{$filename}}, $chunk);
                    }
                    my $oldchunk = $chunk;
                    $chunk                 = {};
                    $chunk->{from}         = {};
                    $chunk->{to}           = {};
                    $chunk->{type}         = "equal";
                    $chunk->{old}->{start} = $oldchunk->{old}->{end} + 1;
                    $chunk->{old}->{end}   = $oldchunk->{old}->{end} + 1;
                    $chunk->{new}->{start} = $oldchunk->{new}->{end} + 1;
                    $chunk->{new}->{end}   = $oldchunk->{new}->{end} + 1;
                } else {
                    $chunk->{new}->{end} += 1;
                    $chunk->{old}->{end} += 1;
                }
                last;
            };
        }
    }

    # Add final diff file section to resulting hash
    if ($filename) {
        push(@{$self->{linemap}->{$filename}}, $chunk);
    }

    if (scalar(keys %{$self->{linemap}}) == 0) {
        # this is probably OK - there are no differences between 'baseline' and current.
        lcovutil::ignorable_error($lcovutil::ERROR_EMPTY,
            "'diff' data file $diff_file contains no differences (this may be OK, if there are no difference between 'baseline' and 'current').\n"
                . "Make sure to use 'diff -u' when generating the diff file.");
    }
    return $self;
}

package SourceLine;

sub new
{
    my $class = shift;
    my @data  = @_;               #[owner, age, line, text, lineCovTla]
    my $self  = \@data;
    bless $self, $class;
    $self->[4] = undef
        if scalar(@$self) < 5;    # set TLA
    $self->[5] = undef
        if scalar(@$self) < 6;    # set branch data
    $self->[6] = undef
        if scalar(@$self) < 7;    # set function data
    return $self;
}

sub owner
{
    my $self = shift;
    return $self->[0];
}

# line coverage TLA
sub tla
{
    my ($self, $tla) = @_;
    $self->[4] = $tla
        if (defined($tla));
    return $self->[4];
}

sub branchElem
{
    my ($self, $branchElem) = @_;
    $self->[5] = $branchElem
        if defined($branchElem);
    return $self->[5];
}

sub functionElem
{
    my ($self, $funcElem) = @_;
    $self->[6] = $funcElem
        if defined($funcElem);
    return $self->[6];
}

sub age
{
    my $self = shift;
    return $self->[1];
}

sub line
{
    my $self = shift;
    return $self->[2];
}

sub text
{
    my $self = shift;
    return $self->[3];
}

package SourceFile;
our $annotateScript;

sub new
{
    # countdata may be 'undef'
    my ($class, $filepath, $fileSummary, $fileCovInfo, $countdata,
        $hasNoBaselineData)
        = @_;

    (ref($fileSummary) eq 'SummaryInfo' &&
     ref($fileCovInfo) eq "FileCoverageInfo") or
        die("unexpected input args");

    my $self = {};
    bless $self, $class;

    $fileSummary->fileDetails($self);
    $self->{_path}       = $filepath;
    $self->{_lines}      = [];          #line coverage data for line
    $self->{_owners}     = {};          # owner -> hash of TLA->list of lines
    $self->{_categories} = {};          # TLA -> list of lines

    $self->{_owners_branch} = {};       # owner -> hash of TLA->list of lines

    # use the line coverage count to synthesize a fake file, if we can't
    #   find an actual file
    $self->_load($countdata, $fileCovInfo->version('current'));

    if ($hasNoBaselineData) {
        my $fileAge = $self->age();
        if (defined($fileAge) &&
            $fileAge > $main::age_basefile) {
            # go through the fileCov data and change UIC->UBC, GIC->CBC
            #  - pretend that we already saw this file data - this is the first
            #    coverage report which contains this data.
            $fileCovInfo->recategorizeTlaAsBaseline();
        }
    }

    if (defined($main::show_dateBins) &&
        !$self->isProjectFile()) {
        lcovutil::info("no owner/date info for '$filepath'\n");
    }

    # sort lines in ascending numerical order - we want the 'owner'
    #   and 'tla' line lists to be sorted - and it is probably faster to
    #   sort the file list once than to sort each of the sub-lists
    #   individually afterward.
    # DCB, DUB category keys have leading "<<<" characters - which we strip
    #  in order to compare
    my $currentTla;
    my $regionStartLine;
    my $lineCovData = $fileCovInfo->lineMap();
    foreach my $line (sort({
                               my $ka =
                                   ("<" ne substr($a, 0, 1)) ? $a :
                                   substr($a, 3);
                               my $kb =
                                   ("<" ne substr($b, 0, 1)) ? $b :
                                   substr($b, 3);
                               $ka <=> $kb
                      } keys(%{$lineCovData}))
    ) {
        my $lne = $lineCovData->{$line};
        $self->_countLineTlaData($line, $lne, $fileSummary);

        $self->_countBranchTlaData($line, $lne, $fileSummary)
            if ($main::br_coverage && defined($lne->differential_branch()));

        $self->_countFunctionTlaData($line, $lne, $fileSummary)
            if ($main::func_coverage && defined($lne->differential_function()));
    }
    return $self;
}

sub _countBranchTlaData
{
    my ($self, $line, $lineData, $fileSummary) = @_;
    my $differentialData = $lineData->differential_branch();

    my %foundBranchTlas;
    my ($src_age, $developer, $srcLine);
    my $lineTla = $lineData->tla();
    if (defined($SourceFile::annotateScript) &&
        'D' ne substr($lineTla, 0, 1)) {
        # deleted lines don't have owner data...
        $srcLine = $self->line($line);
        if (!defined($srcLine)) {
            lcovutil::ignorable_error($ERROR_UNMAPPED_LINE,
                      "no data for 'branch' line:$line, file:" . $self->path());
        } else {
            # if this line is not in the project (e.g., from some 3rd party
            #   library - then we might not have file history for it.
            $src_age   = $srcLine->age();
            $developer = $srcLine->owner();
            $srcLine->branchElem($differentialData);

            if (defined($developer)) {
                my $shash = $self->{_owners_branch};
                if (!exists($shash->{$developer})) {
                    $shash->{$developer} = {};
                    $shash->{$developer}->{lines} = [];
                }
                push(@{$shash->{$developer}->{lines}}, $line);
            }
        }
    }

    my %recorded;
    foreach my $branchId ($differentialData->blocks()) {
        my $diff = $differentialData->getBlock($branchId);
        foreach my $b (@$diff) {
            my $tla = $b->[1];
            unless (defined($tla)) {
                lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                          "undef TLA for branch $branchId of " . $self->path() .
                              ":$line - lineTLA:$lineTla taken:" . $b->[0]);
                next;
            }
            $fileSummary->{branch}->{$tla} += 1;
            # keep track of all the branch TLAs found on this line...
            if (!exists($foundBranchTlas{$tla})) {
                $foundBranchTlas{$tla} = 1;
                $self->{_categories_branch}->{$tla} = []
                    unless exists($self->{_categories_branch}->{$tla});
                push(@{$self->{_categories_branch}->{$tla}}, $line);
            }

            next
                if (0 == ($SummaryInfo::tlaLocation{$tla} & 0x1));
            # skip "DUB' and 'DCB' categories - which are not in current
            #   and thus have no line associated

            # and the age...
            #lcovutil::info("$l: $tla" . $lineData->in_curr() . "\n");

            next unless defined($srcLine) && defined($src_age);

            # increment count of branches of this age we found for this TLA
            $fileSummary->branchCovCount($tla, "age", $src_age, 1);

            # HGC:  could clean this up...no need to keep track
            #   of 'hit' as we can just compute from CBC + GNC + ...
            # found another line...
            my $hit =
                ($tla eq 'GBC' ||
                 $tla eq 'GIC' ||
                 $tla eq 'GNC' ||
                 $tla eq 'CBC');
            $fileSummary->branchCovCount("found", "age", $src_age, 1);
            $fileSummary->branchCovCount("hit", "age", $src_age, 1)
                if $hit;

            next
                unless defined($developer);

            # add this line to those that belong to this owner..

            # first:  increment line count in 'file summary'
            my $ohash = $fileSummary->{owners_branch};
            if (!exists($ohash->{$developer})) {
                my %data = ('hit'   => $hit ? 1 : 0,
                            'found' => 1,
                            $tla    => 1);
                $ohash->{$developer} = \%data;
            } else {
                my $d = $ohash->{$developer};
                $d->{$tla} = 0
                    unless exists($d->{$tla});
                $d->{$tla}  += 1;
                $d->{found} += 1;
                $d->{hit}   += 1
                    if $hit;
            }

            # now append this branchTLA to the owner...
            my $ownerKey = $developer . $tla;
            if (!exists($recorded{$ownerKey})) {
                $recorded{$ownerKey} = 1;
                my $dhash = $self->{_owners_branch}->{$developer};
                $dhash->{$tla} = []
                    unless exists($dhash->{$tla});
                push(@{$dhash->{$tla}}, $line);
            }
        }
    }
}

sub _countLineTlaData
{
    my ($self, $line, $lineData, $fileSummary) = @_;
    # there is differential line coverage data...
    my $tla = $lineData->tla();

    if (!exists($SummaryInfo::tlaLocation{$tla})) {
        # this case can happen if the line number annotations are
        #   wrong in the .info file - so the branch coverage line
        #   number turns out not to be an executable source code line
        lcovutil::ignorable_error($ERROR_UNKNOWN_CATEGORY,
               "unexpected category $tla for line " . $self->path() . ":$line");
        return;
    }
    # one more line in this bucket...
    $fileSummary->{line}->{$tla} += 1;
    # create the category list, if necessary
    $self->{_categories}->{$tla} = []
        unless exists($self->{_categories}->{$tla});

    push(@{$self->{_categories}->{$tla}}, $line);

    # and the age data...

    if ($SummaryInfo::tlaLocation{$tla} & 0x1) {
        # skip "DUB' and 'DCB' categories - which are not in current
        #   and thus have no line associated

        #lcovutil::info("$l: $tla" . $lineData->in_curr() . "\n");

        my $l = $self->line($line);

        if (!defined($l)) {
            lcovutil::ignorable_error($ERROR_UNMAPPED_LINE,
                     "no data for line:$line, TLA:$tla, file:" . $self->path());
            return;
        }
        # set the TLA of this line...
        $l->tla($tla);

        my $src_age = $l->age();
        # if this line is not in the project (e.g., from some 3rd party
        #   library - then we might not have file history for it.
        return
            unless defined($src_age);

        # increment count of lines of this age we found for this TLA
        $fileSummary->lineCovCount($tla, "age", $src_age, 1);

        if ($lineData->in_curr()) {
            # HGC:  could clean this up...no need to keep track
            #   of 'hit' as we can just compute from CBC + GNC + ...
            # found another line...
            $fileSummary->lineCovCount("found", "age", $src_age, 1);
            if ($lineData->curr_count() > 0) {
                $fileSummary->lineCovCount("hit", "age", $src_age, 1);
            }
        }

        if (defined($l->owner())) {
            # add this line to those that belong to this owner..
            my $developer = $l->owner();

            # first:  increment line count in 'file summary'
            my $ohash = $fileSummary->{owners};
            $ohash->{$developer} = {}
                unless exists($ohash->{$developer});
            my $d = $ohash->{$developer};
            $d->{$tla} = 0
                unless exists($d->{$tla});
            $d->{$tla} += 1;

            # now push this line onto the list of in this file, belonging
            #   to this owner
            $self->{_owners}->{$developer} = {}
                unless exists($self->{_owners}->{$developer});
            my $dhash = $self->{_owners}->{$developer};
            $dhash->{lines} = []
                unless exists($dhash->{lines});
            push(@{$dhash->{lines}}, $line);
            $dhash->{$tla} = []
                unless exists($dhash->{$tla});
            # and the list of lines with this TLA, belowing to this user
            push(@{$dhash->{$tla}}, $line);
        }
    }
}

sub _accountFunction
{
    my ($fileSummary, $tla, $src_age) = @_;

    unless (defined($tla)) {
        lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                                  "undef function TLA for age '$src_age' of " .
                                      $fileSummary->name());
        return 1;    # error
    }

    $fileSummary->{function}->{$tla} += 1;

    if (defined($src_age)) {
        $fileSummary->functionCovCount($tla, 'age', $src_age, 1);

        my $hit =
            ($tla eq 'GBC' || $tla eq 'GIC' || $tla eq 'GNC' || $tla eq 'CBC');
        $fileSummary->functionCovCount("found", "age", $src_age, 1);
        $fileSummary->functionCovCount("hit", "age", $src_age, 1)
            if $hit;
    }
    return 0;
}

sub _countFunctionTlaData
{
    my ($self, $line, $lineData, $fileSummary) = @_;
    my $func = $lineData->differential_function();

    my %foundFunctionTlas;
    my ($src_age, $developer, $srcLine);

    my $merged =
        defined($lcovutil::cov_filter[$lcovutil::FILTER_FUNCTION_ALIAS]);
    my $h         = $func->hit();
    my $mergedTla = $h->[1];
    if (!defined($mergedTla)) {
        lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                                  "undef TLA for function '" . $func->name() .
                                      "' hit " . $h->[0] . " at line " .
                                      $line . " (" . $lineData->tla() .
                                      ' ' . $lineData->curr_count() . ")");
        #die("this should not happen");
        # This is new code - somehow miscategorized.
        $mergedTla = $h->[0] == 0 ? 'UNC' : 'GNC';
        $h->[1] = $mergedTla;
        #return;
    }

    if ('D' ne substr($mergedTla, 0, 1)) {
        # deleted lines don't have owner data...
        $srcLine = $self->line($line);
        # info might not be available, if no annotations
        if (defined($srcLine)) {
            # should probably look at the source code to find the open/close
            #  parens - then claim the age is the youngest line
            $src_age = $srcLine->age();
            $srcLine->functionElem($func);
        }
    }

    if ($merged) {
        _accountFunction($fileSummary, $mergedTla, $src_age);
    } else {
        my $aliases = $func->aliases();
        foreach my $alias (keys %$aliases) {
            my $data = $aliases->{$alias};
            my $tla  = $data->[1];
            if (!defined($tla)) {
                lcovutil::ignorable_error($ERROR_INCONSISTENT_DATA,
                    "undef TLA for alias:'$alias' hit:" .
                        $data->[0] . " of function '" . $func->name() .
                        "' hit " . $h->[0] . " at line " . $line . " (" .
                        $lineData->tla() . ' ' . $lineData->curr_count() . ")");
                # die("this should not happen either");
                $tla = $data->[0] == 0 ? 'UNC' : 'GNC';
                $data->[1] = $tla;
            }
            _accountFunction($fileSummary, $tla, $src_age);
        }
    }
}

sub path
{
    my $self = shift;
    return $self->{_path};
}

sub isProjectFile
{
    # return 'true' if no owner/date information for this file.
    my $self = shift;
    return scalar(%{$self->{_owners}});
}

sub line
{
    my $self = shift;
    my $i    = shift;
    die("bad line index '$i'")
        unless ($i =~ /^[0-9]+$/);
    return $self->{_lines}->[$i - 1];
}

# how old is the oldest (or youngest) line in this file?
sub age
{
    my ($self, $youngest) = @_;
    return undef unless $self->isProjectFile();

    my $age = $self->line(1)->age();
    foreach my $line (@{$self->lines()}) {
        my $a = $line->age();
        if (defined($youngest)) {
            $age = $a
                if ($a < $age);
        } else {
            $age = $a
                if ($a > $age);
        }
    }
    return $age;
}

sub lines
{
    my $self = shift;
    return $self->{_lines};
}

sub binarySearchLine
{
    my ($list, $after) = @_;

    defined($list) && 0 != scalar(@$list) or
        die("invalid location list");

    my $max = $#$list;
    my $min = 0;
    my $mid;
    while (1) {
        $mid = int(($max + $min) / 2);
        my $v = $list->[$mid];
        if ($v > $after) {
            $max = $mid;
        } elsif ($v < $after) {
            $min = $mid;
        } else {
            return $mid;
        }
        my $diff = $max - $min;
        if ($diff <= 1) {
            $mid = $min;
            $mid = $max
                if $list->[$min] < $after;
            last;
        }
    }
    return $list->[$mid] >= $after ? $mid : undef;
}

sub nextTlaGroup
{
    # return number of first line of next group of specified linecov TLA -
    #  for example, if line [5:8] and [13:17] are 'CNC', then:
    #     5 = nextTlaGroup('CBC')     : "after == undef"
    #    13 = nextTlaGroup('CBC', 5)  : skip contiguous group of CBC lines
    #  undef = nexTlaGroup('CBC', 13) : no following group
    my ($self, $tla, $after) = @_;
    if (!exists($SummaryInfo::tlaLocation{$tla})) {
        lcovutil::ignorable_error($ERROR_UNKNOWN_CATEGORY,
                                  "unknown linecov TLA '$tla'");
        return undef;
    }

    # note the the "$self->line(...)" argument is 1-based (not zero-base)
    my $line;
    if (defined($after) &&
        defined($self->line($after)->tla())) {
        die("$after is not in $tla group")
            unless ($self->line($after)->tla() eq $tla);
        # skip to the end of the current section...
        # if the TLA of this group is unset (non-code line: comment,
        #   blank, etc) - then look for next code line.  If that line's
        #   TLA matches, then treat as a contiguous group.
        # This way, we avoid visual clutter from having a lot of single-line
        #   TLA segments.
        my $lastline = scalar(@{$self->{_lines}});
        for ($line = $after + 1; $line <= $lastline; ++$line) {
            my $t = $self->line($line)->tla();
            last
                if (defined($t) &&
                    $t ne $tla);
        }
    } else {
        $line = 1;
    }
    my $locations = $self->{_categories}->{$tla};
    my $idx       = binarySearchLine($locations, $line);
    return defined($idx) ? $locations->[$idx] : undef;
}

sub nextBranchTlaGroup
{
    # return number of first line of next group of specified branchcov TLA -
    # note that all branch lines are independent - so we will
    # report and go the next branch, even if it is on the adjacent line
    my ($self, $tla, $after) = @_;
    if (!exists($SummaryInfo::tlaLocation{$tla})) {
        lcovutil::ignorable_error($ERROR_UNKNOWN_CATEGORY,
                                  "unknown branch TLA '$tla'");
        return undef;
    }
    die("no branch data for TLA '$tla'")
        unless exists($self->{_categories_branch}->{$tla});

    my $locations = $self->{_categories_branch}->{$tla};

    $after = defined($after) ? $after + 1 : 1;
    my $idx = binarySearchLine($locations, $after);
    return defined($idx) ? $locations->[$idx] : undef;
}

sub nextInDateBin
{
    my ($self, $dateBin, $tla, $after) = @_;

    if (!exists($SummaryInfo::tlaLocation{$tla})) {
        lcovutil::ignorable_error($ERROR_UNKNOWN_CATEGORY,
                                  "unknown linecov TLA '$tla'");
        return undef;
    }
    $dateBin <= $#SummaryInfo::ageGroupHeader or
        die("unexpected age group $dateBin");

    # note the the "$self->line(...)" argument is 1-based (not zero-base)
    my $line;
    if (defined($after)) {

        ($self->line($after)->tla() eq $tla) or
            die("$after is not in $tla group");

        my $lastline = scalar(@{$self->{_lines}});
        # skip to the end of the current section...
        for ($line = $after + 1; $line <= $lastline; ++$line) {
            my $t = $self->line($line)->tla();
            my $a = $self->line($line)->age();
            if (!defined($a)) {
                lcovutil::ignorable_error($ERROR_UNMAPPED_LINE,
                           "no age data for line:$line, file:" . $self->path());
                return undef;
            }
            last
                if (defined($t) &&
                    ($t ne $tla ||
                     $dateBin != SummaryInfo::findAgeBin($a)));
        }
    } else {
        $line = 1;
    }
    # the data isn't stored by date bin (at least for now) - so the
    #   only way to find it currently is by searching forward.
    my $tlaLocations = $self->{_categories}->{$tla};
    my $idx          = binarySearchLine($tlaLocations, $line);
    return undef unless defined($idx);
    my $max = scalar(@$tlaLocations);
    for (; $idx < $max; ++$idx) {
        $line = $tlaLocations->[$idx];
        my $l = $self->line($line);
        if (!defined($l)) {
            lcovutil::ignorable_error($ERROR_UNMAPPED_LINE,
                               "no data for line:$line, file:" . $self->path());
            return undef;
        }
        my $a = $l->age();
        if (!defined($a)) {
            lcovutil::ignorable_error($ERROR_UNMAPPED_LINE,
                           "no age data for line:$line, file:" . $self->path());
            return undef;
        }
        my $bin = SummaryInfo::findAgeBin($a);

        if ($bin == $dateBin) {
            my $t = $l->tla();
            return $line
                if (defined($t) &&
                    $t eq $tla);
        }
    }
    return undef;
}

sub nextInOwnerBin
{
    my ($self, $owner, $tla, $after) = @_;

    if (!exists($SummaryInfo::tlaLocation{$tla})) {
        lcovutil::ignorable_error($ERROR_UNKNOWN_CATEGORY,
                                  "unknown linecov TLA '$tla'");
        return undef;
    }
    exists($self->{_owners}->{$owner}) &&
        exists($self->{_owners}->{$owner}->{$tla}) or
        die("$owner not responsible for any $tla lines in" . $self->path());

    # note the the "$self->line(...)" argument is 1-based (not zero-base)
    my $line;
    if (defined($after)) {

        ($self->line($after)->tla() eq $tla) or
            die("$after is not in $tla group");

        my $lastline = scalar(@{$self->{_lines}});
        # skip to the end of the current section...
        for ($line = $after + 1; $line <= $lastline; ++$line) {
            my $l = $self->line($line);
            if (!defined($l)) {
                lcovutil::ignorable_error($ERROR_UNMAPPED_LINE,
                               "no data for line:$line, file:" . $self->path());
                return undef;
            }
            my $t = $l->tla();
            my $o = $l->owner();
            if (!defined($o)) {
                lcovutil::ignorable_error($ERROR_UNMAPPED_LINE,
                         "no owber data for line:$line, file:" . $self->path());
                return undef;
            }
            last
                if (defined($t) &&
                    ($t ne $tla ||
                     $o ne $owner));
        }
    } else {
        $line = 1;
    }

    my $locations = $self->{_owners}->{$owner}->{$tla};
    my $idx       = binarySearchLine($locations, $line);
    return defined($idx) ? $locations->[$idx] : undef;
}

sub nextBranchInDateBin
{
    my ($self, $dateBin, $tla, $after) = @_;

    if (!exists($SummaryInfo::tlaLocation{$tla})) {
        lcovutil::ignorable_error($ERROR_UNKNOWN_CATEGORY,
                                  "unknown branch TLA '$tla'");
        return undef;
    }
    $dateBin <= $#SummaryInfo::ageGroupHeader or
        die("unexpected age group $dateBin");

    # note the the "$self->line(...)" argument is 1-based (not zero-base)
    $after = defined($after) ? $after + 1 : 1;

    exists($self->{_categories_branch}->{$tla}) or
        die("no $tla branches in " . $self->path());

    my $lines = $self->{_categories_branch}->{$tla};
    my $idx   = binarySearchLine($lines, $after);

    return undef unless defined($idx);
    my $max = scalar(@$lines);
    for (; $idx < $max; ++$idx) {
        my $line = $lines->[$idx];
        my $l    = $self->line($line);
        if (!defined($l)) {
            lcovutil::ignorable_error($ERROR_UNMAPPED_LINE,
                               "no data for line:$line, file:" . $self->path());
            next;
        }
        my $a = $l->age();
        if (!defined($a)) {
            lcovutil::ignorable_error($ERROR_UNMAPPED_LINE,
                           "no age data for line:$line, file:" . $self->path());
            return undef;
        }
        my $bin = SummaryInfo::findAgeBin($a);
        if ($bin == $dateBin) {
            return $line;
        }
    }
    return undef;
}

sub nextBranchInOwnerBin
{
    my ($self, $owner, $tla, $after) = @_;

    if (!exists($SummaryInfo::tlaLocation{$tla})) {
        lcovutil::ignorable_error($ERROR_UNKNOWN_CATEGORY,
                                  "unknown branch TLA '$tla'");
        return undef;
    }

    # note the the "$self->line(...)" argument is 1-based (not zero-base)
    $after = defined($after) ? $after + 1 : 1;

    if (exists($self->{_owners_branch}->{$owner})) {
        my $od = $self->{_owners_branch}->{$owner};
        if (exists($od->{$tla})) {
            my $l   = $od->{$tla};
            my $idx = binarySearchLine($l, $after);
            return defined($idx) ? $l->[$idx] : undef;
        }
    }
    return undef;
}

sub _computeAge
{
    my $when = shift;

    # a hack for the production of stable examples for publication:
    #   if the 'when' value is an integer, treat it as a day count
    #   (rather than a date) - so the HTML result is stable
    #   (where age does not change every time the example runs).
    return $when
        if ($when =~ /^[0-9]+$/);

    return DateTime::Format::W3CDTF->parse_datetime($when)
        ->delta_days(DateTime->now())->in_units('days');
}

sub _load
{
    my ($self, $countdata, $currentVersion) = @_;

    my $start  = Time::HiRes::gettimeofday();
    my $lineno = 0;
    local *HANDLE;    # File handle for reading the diff file

    # Check if file exists and is readable
    if (!(-r $self->path())) {
        $self->_synthesize($countdata);
        my $end = Time::HiRes::gettimeofday();
        $lcovutil::profileData{synth}{$self->path()} = $end - $start;
        return $self;
    }

    # check for version mismatch...
    if ($lcovutil::extractVersionScript) {
        my $version = lcovutil::extractFileVersion($self->path());

        lcovutil::checkVersionMatch($self->path(), $version, $currentVersion);
        my $end = Time::HiRes::gettimeofday();
        $lcovutil::profileData{check_version}{$self->path()} = $end - $start;
    }

    #stat($annotateScript);
    if (!defined($annotateScript)) {
        my $begin = Time::HiRes::gettimeofday();
        $self->_bare_load();
        my $end = Time::HiRes::gettimeofday();
        $lcovutil::profileData{load}{$self->path()} = $end - $begin;
        return $self;
    }

    my $begin     = Time::HiRes::gettimeofday();
    my $repo_path = Cwd::realpath($self->path());

    my $lineNum = 0;
    my @cmd     = split(' ', $annotateScript);
    splice(@cmd, 1, 0, $repo_path);
    my $cmd = join(' ', @cmd);
    lcovutil::info(1, "annotate: '$cmd'\n");
    my $found;    # check that either all lines are annotated or none are
    if (open(HANDLE, "-|", $cmd)) {
        while (my $line = <HANDLE>) {
            chomp $line;
            $line =~ s/\r//g;    # remove CR from line-end
            ++$lineNum;

            my ($commit, $owner, $when, $text) = split(/\|/, $line, 4);
            my $age = _computeAge($when);
            if ($commit ne 'NONE') {
                die("inconsistent 'annotate' data for '$repo_path': both 'commit' and 'no commit' lines"
                ) if (defined($found) && !$found);
                $found = 1;
                $found = 1;

                defined($owner) or
                    die("owner is undef for $repo_path:$lineNum");
                $self->{_owners}->{$owner} = {}
                    unless exists($self->{_owners}->{$owner});
                my $dhash = $self->{_owners}->{$owner};
                $dhash->{lines} = []
                    unless exists($dhash->{lines});
                push(@{$dhash->{lines}}, $lineNum);
            } else {
                die("inconsistent 'annotate' data for '$repo_path': both 'no commit' and 'commit' lines"
                ) if (defined($found) && $found);
                $found = 0;
                $owner = "no.body";
            }
            push @{$self->{_lines}},
                SourceLine->new($owner, $age, $lineNum, $text);
        }
        close(HANDLE);
        my $status = $? >> 8;
        0 == $status
            or
            lcovutil::ignorable_error($ERROR_ANNOTATE_SCRIPT,
                              $! ? "annotate command '$cmd' pipe error: $!" :
                                  "non-zero exit status from annotate '$cmd' pipe"
            );
    } else {
        print("Error: 'open(-| $cmd)' failed: \"$!\"\n");
    }
    my $end = Time::HiRes::gettimeofday();
    $lcovutil::profileData{annotate}{$self->path()} = $end - $begin;
    return $self;
}

sub _synthesize
{
    my ($self, $countdata) = @_;

    # Synthesize source data from coverage trace to replace unreadable file
    my $last_line = 0;

    lcovutil::ignorable_error($lcovutil::ERROR_SOURCE,
             "cannot read '" . $self->path() . "' - synthesizing fake content");
    return $self if (!defined($countdata));
    my @lines = sort({ $a <=> $b } $countdata->keylist());
    if (@lines) {
        $last_line = $lines[scalar(@lines) - 1];
    }
    return $self if ($last_line < 1);

    # Simulate gcov behavior
    my $notFound = "/* " . $self->path() . " not found */";
    my $synth    = "/* (content generated from line coverage data) */";
    for (my $line = 1; $line <= $last_line; $line++) {
        my $mod = $line % 20;
        my $l = (($mod == 1) ? $notFound :
                     ($mod == 2) ? $synth :
                     "/* ... */");
        push @{$self->{_lines}}, SourceLine->new(undef, undef, $line, $l);
    }
    return $self;
}

sub _bare_load
{
    my $self = shift;

    my $lineno = 0;
    local *HANDLE;    # File handle for reading the diff file

    open(HANDLE, "<", $self->path()) or
        die("unable to open '" . $self->path() . "': $!\n");
    while (my $line = <HANDLE>) {
        chomp $line;
        $line =~ s/\r//g;    # Also remove CR from line-end

        $lineno++;
        push @{$self->{_lines}}, SourceLine->new(undef, undef, $lineno, $line);
    }
    close(HANDLE);
    return $self;
}

# a class to hold either line or branch counts for each testcase -
#   used by the "--show-details" feature.
package TestcaseTlaCount;

sub new
{
    # $testcaseCounts: either 'CountData' or 'BranchData' structure
    #     - the data for this testcase
    # $fileDetails: SourceFile structure - data for the filename
    # $covtype:  'line' or 'branch'
    my ($class, $testcaseCounts, $fileDetails, $covtype) = @_;

    my $merged =
        defined($lcovutil::cov_filter[$lcovutil::FILTER_FUNCTION_ALIAS]);
    my %tlaData;
    if ($covtype ne 'function') {
        $tlaData{found} = $testcaseCounts->found();
        $tlaData{hit}   = $testcaseCounts->hit();
    } else {
        $tlaData{found} = $testcaseCounts->numFunc($merged);
        $tlaData{hit}   = $testcaseCounts->numHit($merged);
    }
    if ($main::show_tla &&
        defined($fileDetails)) {
        for my $tla (("CBC", "GBC", "GIC", "GNC")) {
            $tlaData{$tla} = 0;
        }
        if ('line' eq $covtype) {
            foreach my $line ($testcaseCounts->keylist()) {
                # skip uncovered lines...
                next if $testcaseCounts->value($line) == 0;
                my $lineData =
                    $fileDetails->line($line);    # "SourceLine" structure
                my $tla = $lineData->tla();
                die("unexpected TLA '$tla' in CounntData for line $line")
                    unless exists($tlaData{$tla});
                $tlaData{$tla} += 1;
            }
        } elsif ('branch' eq $covtype) {
            foreach my $line ($testcaseCounts->keylist()) {
                my $lineData =
                    $fileDetails->line($line);    # "SourceLine" structure
                my $branchEntry = $lineData->branchElem();
                foreach my $id ($branchEntry->blocks()) {
                    my $block = $branchEntry->getBlock($id);
                    foreach my $data (@$block) {
                        my ($br, $tla) = @$data;
                        my $count = $br->count();
                        die("unexpected branch TLA $tla for count $count at " .
                            $fileDetails->path() . ":$line")
                            unless (($count != 0) == exists($tlaData{$tla}));
                        next if (0 == $count);
                        $tlaData{$tla} += 1;
                    }
                }
            }
        } else {
            die("$covtype not supported yet") unless $covtype eq 'function';
            foreach my $key ($testcaseCounts->keylist()) {
                my $func = $testcaseCounts->findKey($key);
                my $line = $func->line();
                # differential FunctionEntry
                my $lineData     = $fileDetails->line($line);
                my $differential = $lineData->functionElem();
                my @data;
                if ($merged) {
                    push(@data, $differential->hit());
                } else {
                    my $aliases = $differential->aliases();
                    foreach my $alias (keys %$aliases) {
                        push(@data, $aliases->{$alias});
                    }
                }
                foreach my $d (@data) {
                    my ($count, $tla) = @$d;
                    die("unexpected branch TLA $tla for count $count")
                        unless (($count != 0) == exists($tlaData{$tla}));
                    #next if (0 == $count);
                    $tlaData{$tla} += 1;
                }
            }
        }
    }
    my $self = [$testcaseCounts, $fileDetails, \%tlaData, $covtype];
    bless $self, $class;
    return $self;
}

sub covtype
{
    my $self = shift;
    return $self->[3];
}

sub count
{
    my ($self, $tla) = @_;

    my $tlaCounts = $self->[2];
    return exists($tlaCounts->{$tla}) ? $tlaCounts->{$tla} : 0;
}

package GenHtml;

our $WORKLIST_IDX  = 1;
our $PENDING_IDX   = 2;
our $CHILDDATA_IDX = 3;

sub new
{
    my ($class, $current_data) = @_;
    my $self = [
           SummaryInfo->new("top", ''),    # top has empty name
           [], # worklist: dependencies are complete - this can run immediately
           {}, # %pending; # map of name->list of as-yet incomplete dependencies
               # This task can be scheduled as soon as its last dependency
               #  is complete.
           {}, # childData - for callback
           File::Temp->newdir("genhtml_XXXX",
                              DIR     => $lcovutil::tmp_dir,
                              CLEANUP => 1)
    ];
    bless $self, $class;

    lcovutil::info(1, "Writing temporary data to " . $self->[4]);
    my $pending           = $self->[$PENDING_IDX];
    my $worklist          = $self->[$WORKLIST_IDX];
    my $top_level_summary = $self->[0];
    # no parent data for top-level
    $pending->{""} = [
                      ['top',
                       [$top_level_summary, undef, $top_level_summary->name()]
                       ,    # summary, per-test data, name
                       ['root'], ['root'],
                       [undef, undef]
                      ],
                      {}
    ];

    foreach my $f ($current_data->files()) {
        my $parentDir = main::shorten_prefix($f);
        my $short_name =
            $main::no_prefix ? $f : main::apply_prefix($f, @main::dir_prefix);
        my $is_absolute = $short_name =~ /^\//;
        $short_name =~ s|^/||;
        my @short_path = split('/', $short_name);
        my @path       = split('/', $parentDir);

        my @rel_dir_stack =
            @short_path;    # @rel_dir_stack: relative path to parent dir of $f
        pop(@rel_dir_stack);    # remove filename from the end
        my $pendingParent;
        if ($main::hierarchical) {
            # excludes trailing '/'
            my $base          = substr($f, 0, -(length($short_name) + 1));
            my $relative_path = "";
            my $path          = $base;
            $pendingParent =
                $pending->{""};    # this is the top-level object dependency
            my @sp;
            my @p = split('/', substr($base, 0, -1));    # remove trailing '/'
            while (scalar(@rel_dir_stack)) {
                my $element = shift(@rel_dir_stack);
                $relative_path .= $element;
                $path          .= '/' . $element;
                push(@p, $element);
                push(@sp, $element);
                if (exists($pending->{$path})) {
                    $pendingParent = $pending->{$path};
                } else {
                    my $perTestData = [{}, {}, {}];

                    my @dirData = (SummaryInfo->new("directory", $relative_path,
                                                    $is_absolute),
                                   $perTestData,
                                   $path);
                    add_dependency($pendingParent, $path);
                    my @spc = @sp;
                    my @pc  = @p;
                    $pendingParent = [
                                      ['dir', \@dirData,
                                       \@spc, \@pc,
                                       $pendingParent
                                      ],
                                      {}
                    ];
                    die("unexpected pending entry")
                        if exists($pending->{$dirData[2]});
                    $pending->{$dirData[2]} = $pendingParent;
                }
                $relative_path .= '/';
            }
        } else {
            # not hierarchical
            my $relative_path = join('/', @rel_dir_stack);
            if (!exists($pending->{$parentDir})) {
                my $perTestData = [{}, {}, {}];
                my @dirData = (SummaryInfo->new(
                                       "directory", $relative_path, $is_absolute
                               ),
                               $perTestData,
                               $parentDir);
                $pending->{$parentDir} = [
                                     ['dir', \@dirData, \@rel_dir_stack, \@path,
                                      $pending->{$top_level_summary->name()}
                                     ],
                                     {}
                ];
            }
            $pendingParent = $pending->{$parentDir};

            # my directory is dependency for the top-level
            add_dependency($pending->{$top_level_summary->name()}, $parentDir);
        }

        # current file is a dependency of the directory...
        add_dependency($pendingParent, $f);
        # this file is ready to be processed
        my @fileData = (SummaryInfo->new("file", $f), [{}, {}, {}], $f);
        push(@$worklist,
             ['file', \@fileData, \@short_path, \@path, $pendingParent]);
    }

    $self->compute();
    return $self;
}

sub top()
{
    my $self = shift;
    return $self->[0];
}

sub add_dependency
{
    my ($parent, $name) = @_;
    lcovutil::info(2,
                   "add depend $name' in -> " . $parent->[0]->[1]->[2] . "\n")
        unless exists($parent->[1]->{$name});
    $parent->[1]->{$name} = 1;
}

sub completed_dependency
{
    # return 0 when last dependency is removed
    my ($self, $parent, $name) = @_;

    my $pending = $self->[$PENDING_IDX];
    die("missing pending '$parent'")
        unless exists($pending->{$parent});
    my $pendingParent = $pending->{$parent};
    die("missing pending entry for $name (in $parent")
        unless exists($pendingParent->[1]->{$name});
    delete($pendingParent->[1]->{$name});
    if (!%{$pendingParent->[1]}) {
        # no more dependencies - schedule this one
        push(@{$self->[$WORKLIST_IDX]}, $pendingParent->[0]);
        delete($pending->{$parent});
    }
}

sub compute
{
    my $self = shift;

    my $currentParallel = 0;
    my $worklist        = $self->[$WORKLIST_IDX];
    my $pending         = $self->[$PENDING_IDX];
    my $children        = $self->[$CHILDDATA_IDX];
    while (@$worklist ||
           %$pending) {

        if (1 < $lcovutil::maxParallelism) {

            my $currentSize = 0;
            if (0 != $lcovutil::maxMemory) {
                $currentSize = lcovutil::current_process_size();
            }

            while ($currentParallel >= $lcovutil::maxParallelism ||
                   ($currentParallel > 1 &&
                    (($currentParallel + 1) * $currentSize) >
                    $lcovutil::maxMemory) ||
                   (0 == @$worklist &&
                    %$pending)
            ) {
                lcovutil::info(1,
                    "memory constraint ($currentParallel + 1) * $currentSize > $lcovutil::maxMemory violated: waiting."
                        . (scalar(@$worklist) + scalar(keys(%$pending)))
                        . " remaining\n")
                    if ((($currentParallel + 1) * $currentSize) >
                        $lcovutil::maxMemory);
                my $child       = wait();
                my $childstatus = $?;
                --$currentParallel;
                my ($summary, $fullname, $parentData, $now) =
                    @{$children->{$child}};
                my ($parentSummary, $parentPerTestData, $parentPath) =
                    @{$parentData->[0]->[1]};

                $self->merge_child($child, $childstatus);

                delete($children->{$child});

                if ($summary->type() ne 'top') {
                    # remove current object from dependencies...
                    $self->completed_dependency($parentPath, $fullname);
                }
            }
        }
        my $task = pop(@$worklist);
        my ($type, $data, $short_path, $path, $parentData) = @$task;
        my ($selfSummary, $perTestData, $name) = @$data;
        #main::info("$type: $name\n");
        my ($parentSummary, $parentPerTestData, $parentPath) =
            @{$parentData->[0]->[1]}
            unless 'top' eq $type;

        my $start = Time::HiRes::gettimeofday();

        my $rel_dir;
        if ($type eq 'file') {
            $rel_dir = join('/', @{$short_path}[0 .. $#$short_path - 1]);
            die("file error for " . join('/', @$short_path))
                if '' eq $rel_dir;
        } elsif ($type eq 'dir') {
            $rel_dir = join('/', @$short_path);
        } else {
            $rel_dir = '.';
        }

        File::Path::make_path($rel_dir) unless -d $rel_dir;
        my $base_dir  = main::get_relative_base_path($rel_dir);
        my $trunc_dir = ($rel_dir eq '') ? 'root' : $rel_dir;

        if (1 < $lcovutil::maxParallelism) {
            my $pid = fork();
            if (0 == $pid) {
                # I'm the child
                # clear the profile data - we want just my contribution
                my $childStart = Time::HiRes::gettimeofday();
                %lcovutil::profileData = ();
                my $tmp         = '' . $self->[4];
                my $stdout_file = "$tmp/genhtml_$$.log";
                my $stderr_file = "$tmp/genhtml_$$.err";
                local (*STDERR);
                local (*STDOUT);
                open(STDOUT1, '>' . $stdout_file) or
                    die($stdout_file . ': ' . $!);
                open(STDERR1, '>' . $stderr_file) or
                    die($stderr_file . ': ' . $!);
                open(STDOUT, ">&STDOUT1") or
                    die("could not redirect stdout: $!");
                open(STDERR, ">&STDERR1") or
                    die("could not redirect stderr: $!");

                if ('file' eq $type) {
                    ($perTestData->[0], $perTestData->[1], $perTestData->[2]) =
                        main::process_file($selfSummary, $parentSummary,
                                           $trunc_dir, $rel_dir, $name);
                } elsif ('dir' eq $type) {
                    # Create sorted summary pages
                    main::write_summary_pages(
                                            $name, 1,    # this is a directory,
                                            $selfSummary, $main::show_details,
                                            $rel_dir, $base_dir, $trunc_dir,
                                            $perTestData);
                } else {
                    die("unexpected task '" . join(' ', @$task) . ".")
                        unless 'top' eq $type;

                    # Generate overview page
                    lcovutil::info("Writing top-level directory view page.\n");
                    # Create sorted pages
                    main::write_summary_pages(
                        $name, 0,                        # 0 == list directories
                        $selfSummary,
                        0, # don't generate 'details' links for top-level report
                        ".", "", undef, undef);
                }

                $selfSummary->checkCoverageCriteria();
                # clear the parent pointer that we hacked into place.  Don't want that
                #   extra data returned by dumper.
                $selfSummary->{parent}  = undef;
                $selfSummary->{sources} = {}
                    if exists($selfSummary->{sources});
                my $name =
                    $selfSummary->type() eq 'top' ? "" : $selfSummary->name();
                my $criteria = $SummaryInfo::coverageCriteria{$name}
                    if exists($SummaryInfo::coverageCriteria{$name});
                my $file = "$tmp/dumper_$$";

                my $childEnd = Time::HiRes::gettimeofday();
                $lcovutil::profileData{child}{$name} = $childEnd - $childStart;
                Storable::store([$perTestData, $selfSummary,
                                 $criteria, \%lcovutil::profileData
                                ],
                                $file);
                close(STDOUT1);
                close(STDERR1);
                exit(0);
            } else {
                $children->{$pid} = [$selfSummary, $name, $parentData, $start];
                ++$currentParallel;
            }
        } else {
            #not parallel

            if ('file' eq $type) {
                my ($testdata, $testfncdata, $testbrdata) =
                    main::process_file($selfSummary, $parentSummary,
                                       $trunc_dir, $rel_dir, $name);
                my $base_name = File::Basename::basename($name);

                $perTestData->[0]{$base_name} = $testdata;
                $perTestData->[1]{$base_name} = $testfncdata;
                $perTestData->[2]{$base_name} = $testbrdata;
                $parentSummary->append($selfSummary);
            } elsif ('dir' eq $type) {
                # process the directory...
                main::write_summary_pages($name, 1,    # this is a directory,
                                          $selfSummary, $main::show_details,
                                          $rel_dir, $base_dir, $trunc_dir,
                                          $perTestData);
                $parentSummary->append($selfSummary);
            } else {
                die("unexpected task '" . join(' ', @$task) . ".")
                    unless 'top' eq $type;
                # Create sorted pages
                main::write_summary_pages(
                       $name, 0,                       # 0 == list directories
                       $selfSummary,
                       0,  # don't generate 'details' links for top-level report
                       ".", "", undef, undef);
            }
            $selfSummary->checkCoverageCriteria();

            # remove current object from dependencies...
            if ($type ne 'top') {
                $self->completed_dependency($parentPath, $name);
            }
            my $end = Time::HiRes::gettimeofday();
            $lcovutil::profileData{$type}{$name} = $end - $start;
        }
    }    # foreach

    while ($currentParallel != 0) {
        my $child       = wait();
        my $childstatus = $?;
        --$currentParallel;
        my ($summary, $fullname, $parentSummary, $parentPath, $now) =
            @{$children->{$child}};
        $self->merge_child($child, $childstatus);

        # remove current object from dependencies...
        if ($summary->type() ne 'top') {
            die("did not expect to get here.." .
                $summary->type() . " $currentParallel");

            $self->completed_dependency($parentPath, $fullname);
        }
    }
}

sub merge_child($$$)
{
    my ($self, $childPid, $childstatus) = @_;
    my $children = $self->[$CHILDDATA_IDX];

    my ($childSummary, $fullname, $parentData, $start) =
        @{$children->{$childPid}};
    my $type = $childSummary->type();
    my ($parentSummary, $parentPerTestData, $parentPath) =
        @{$parentData->[0]->[1]}
        unless $type eq 'top';

    my $tmp      = '' . $self->[4];
    my $dumpfile = "$tmp/dumper_$childPid";
    my $childLog = "$tmp/genhtml_$childPid.log";
    my $childErr = "$tmp/genhtml_$childPid.err";
    foreach my $f ($childLog, $childErr) {
        if (open(RESTORE, "<", $f)) {
            # slurp into a string and eval..
            my $str = do { local $/; <RESTORE> };    # slurp whole thing
            close(RESTORE);
            unlink $f;
            $f = $str;
        } else {
            report_parallel_error('lcov', "unable to open $f: $!");
        }
    }
    print(STDOUT $childLog)
        if (0 != $childstatus ||
            $lcovutil::verbose);
    print(STDERR $childErr);

    if (0 == $childstatus) {
        # now undump the data ...
        my $data = Storable::retrieve($dumpfile);
        if (defined($data)) {
            my ($perTest, $summary, $criteria, $profile) = @$data;

            $childSummary->copyGuts($summary);
            if ('file' eq $type) {
                my $base_name = File::Basename::basename($fullname);
                for (my $i = 0; $i < 3; $i++) {
                    $parentPerTestData->[$i]->{$base_name} = $perTest->[$i];
                }
            } elsif ('directory' eq $type) {
                for (my $i = 0; $i < 3; $i++) {
                    while (my ($basename, $data) = each(%{$perTest->[$i]})) {
                        $parentPerTestData->[$i]->{$basename} = $data;
                    }
                }
            } else {
                die("unexpected type $type")
                    unless $type eq 'top';
                $self->[0] = $summary;    # set the top-level to this value...
            }
            $parentSummary->append($childSummary)
                unless $type eq 'top';
            if (defined($criteria)) {
                my $name =
                    $childSummary->type() eq 'top' ? "" : $childSummary->name();
                $SummaryInfo::coverageCriteria{$name} = $criteria;
                $SummaryInfo::coverageCriteriaStatus = $criteria->[1]
                    if ($criteria->[1] != 0 ||
                        0 != scalar(@{$criteria->[2]}));
            }
            lcovutil::merge_child_profile($profile);
        } else {
            lcovutil::report_parallel_error('genhtml',
                                            "unable to deserialize $dumpfile");
        }
    } else {
        lcovutil::report_parallel_error('genhtml',
                         "child $childPid returned non-zero code $childstatus");
    }
    my $end = Time::HiRes::gettimeofday();
    $lcovutil::profileData{$type}{$fullname} = $end - $start;

    unlink $dumpfile
        if -f $dumpfile;
}

package main;

# Global variables & initialization

# Instance containing all data from the 'current' .info file
our $current_data = TraceFile->new();
# Instance containing all data from the baseline .info file (if any)
our $base_data = TraceFile->new();
# Instance containing all data from diff file
our $diff_data = LineMap->new();
our @opt_dir_prefix;    # Array of prefixes to remove from all sub directories
our @dir_prefix;
our %test_description;    # Hash containing test descriptions if available
our $current_date = get_date_string(undef);

our @info_filenames;      # List of .info files to use as data source
our $header_title;        # Title at top of HTML report page (above table)
our $footer;              # String at bootom of HTML report page
our $test_title;          # Title for output as written to each page header
our $output_directory;    # Name of directory in which to store output
our $base_filename;       # Optional name of file containing baseline data
our $age_basefile;        # how old is the baseline data file?
our $baseline_title;      # Optional name of baseline - written to page headers
our $baseline_date;       # Optional date that baseline was created
our $diff_filename;       # Optional name of file containing baseline data
our $strip;               # If set, strip leading directories when applying diff
our $desc_filename;       # Name of file containing test descriptions
our $css_filename;        # Optional name of external stylesheet file to use
our $help;                # Help option flag
our $version;             # Version option flag
our $show_details;        # If set, generate detailed directory view
our $no_prefix;           # If set, do not remove filename prefix
our $func_coverage;       # If set, generate function coverage statistics
our $no_func_coverage;    # Disable func_coverage
our $br_coverage;         # If set, generate branch coverage statistics
our $no_br_coverage;      # Disable br_coverage
our $show_tla;            # categorize coverage data (or not)
our $show_hitTotalCol;    # include the 'hit' or 'missed' total count in tables
                          #   - this is part of the 'legacy' view
    #   - also enabled when full differential categories are used
    #     (i.e., but not when there is no baseline data - so no
    #     categories apart from 'GNC' and 'UNC'
our $use_legacyLabels;
our $show_dateBins;         # show last modified and last author info
our $show_ownerBins;        # show list of people who have edited code
                            #   (in this file/this directory/etc)
our $show_nonCodeOwners;    # show last modified and last author info for
                            #  non-code lines (e.g., comments)
our $show_simplifiedColors;
our $treatNewFileAsBaseline;
our $elide_path_mismatch =
    0;                 # handle case that file in 'baseline' and 'current' .info
                       # data matches some name in the 'diff' file such that
                       # the basename is the same but the pathname is different
                       # - then pretend that the names DID match
our $hierarchical = 0; # if true: show directory hierarchy
                       # default: legacy two-level report

our $sort = 1;          # If set, provide directory listings with sorted entries
our $no_sort;           # Disable sort
our $frames;            # If set, use frames for source code view
our $keep_descriptions; # If set, do not remove unused test case descriptions
our $no_sourceview;     # If set, do not create a source code view for each file
our $highlight;         # If set, highlight lines covered by converted data only
our $legend;            # If set, include legend in output
our $tab_size = 8;      # Number of spaces to use in place of tab
our $html_prolog_file;  # Custom HTML prolog file (up to and including <body>)
our $html_epilog_file;  # Custom HTML epilog file (from </body> onwards)
our $html_prolog;       # Actual HTML prolog
our $html_epilog;       # Actual HTML epilog
our $html_ext  = "html";    # Extension for generated HTML files
our $html_gzip = 0;         # Compress with gzip
our @opt_ignore_errors;     # Ignore certain error classes during processing
our @opt_filter;            # Filter out requested coverpoints
our @ignore;
our @opt_config_file;             # User-specified configuration files (paths)
our $opt_missed;                  # List/sort lines by missed counts
our $dark_mode;                   # Use dark mode palette or normal
our $charset = "UTF-8";           # Default charset for HTML pages
our @fileview_sortlist;
our @fileview_sortname = ("", "-sort-l", "-sort-f", "-sort-b");
our @fileview_prefixes = ("");
our @funcview_sortlist;
our @rate_name            = ("Lo", "Med", "Hi");
our @rate_png             = ("ruby.png", "amber.png", "emerald.png");
our $lcov_func_coverage   = 1;
our $lcov_branch_coverage = 0;
our $rc_desc_html         = 0;    # lcovrc: genhtml_desc_html

our $cwd = cwd();                 # Current working directory

#
# Code entry point
#

$SIG{__WARN__} = \&lcovutil::warn_handler;
$SIG{__DIE__}  = \&lcovutil::die_handler;

STDERR->autoflush;
STDOUT->autoflush;

my $rtlExtensions;
my $cExtensions;
my @datebins;

# retrieve settings from RC file - use these if not overridden on command line
my (@rc_datebins, @rc_filter, @rc_ignore,
    @rc_exclude_patterns, @rc_include_patterns, @rc_subst_patterns,
    @rc_omit_patterns);

lcovutil::apply_rc_params(\@opt_config_file,
                          {
                           "genhtml_css_file"          => \$css_filename,
                           "genhtml_header"            => \$header_title,
                           "genhtml_footer"            => \$footer,
                           "genhtml_hi_limit"          => \$hi_limit,
                           "genhtml_med_limit"         => \$med_limit,
                           "genhtml_line_field_width"  => \$line_field_width,
                           "genhtml_overview_width"    => \$overview_width,
                           "genhtml_nav_resolution"    => \$nav_resolution,
                           "genhtml_nav_offset"        => \$nav_offset,
                           "genhtml_keep_descriptions" => \$keep_descriptions,
                           "genhtml_no_prefix"         => \$no_prefix,
                           "genhtml_no_source"         => \$no_sourceview,
                           "genhtml_num_spaces"        => \$tab_size,
                           "genhtml_highlight"         => \$highlight,
                           "genhtml_legend"            => \$legend,
                           "genhtml_html_prolog"       => \$html_prolog_file,
                           "genhtml_html_epilog"       => \$html_epilog_file,
                           "genhtml_html_extension"    => \$html_ext,
                           "genhtml_html_gzip"         => \$html_gzip,
                           "genhtml_precision" => \$lcovutil::default_precision,
                           "genhtml_function_hi_limit"  => \$fn_hi_limit,
                           "genhtml_function_med_limit" => \$fn_med_limit,
                           "genhtml_function_coverage"  => \$func_coverage,
                           "genhtml_branch_hi_limit"    => \$br_hi_limit,
                           "genhtml_branch_med_limit"   => \$br_med_limit,
                           "genhtml_branch_coverage"    => \$br_coverage,
                           "genhtml_branch_field_width" => \$br_field_width,
                           "genhtml_sort"               => \$sort,
                           "genhtml_charset"            => \$charset,
                           "genhtml_desc_html"          => \$rc_desc_html,
                           "genhtml_demangle_cpp" => \$lcovutil::cpp_demangle,
                           "genhtml_demangle_cpp_tool" => \$lcovutil::cpp_demangle_tool,
                           "genhtml_demangle_cpp_params" => \$lcovutil::cpp_demangle_params,
                           "genhtml_missed"          => \$opt_missed,
                           "genhtml_dark_mode"       => \$dark_mode,
                           "genhtml_hierarchical"    => \$hierarchical,
                           "genhtml_show_havigation" => \$show_tla,
                           'genhtml_annotate_script' => \$SourceFile::annotateScript,
                           'genhtml_criteria_script' => \$SummaryInfo::coverageCriteriaScript,
                           'genhtml_date_bins' => \@rc_datebins,

                           "lcov_tmp_dir"     => \$lcovutil::tmp_dir,
                           "lcov_json_module" => \$JsonSupport::rc_json_module,
                           "lcov_function_coverage" => \$lcov_func_coverage,
                           "lcov_branch_coverage"   => \$lcov_branch_coverage,
                           "ignore_errors"          => \@rc_ignore,
                           "max_message_count"   => \$lcovutil::suppressAfter,
                           'stop_on_error'       => \$lcovutil::stop_on_error,
                           "rtl_file_extensions" => \$rtlExtensions,
                           "c_file_extensions"   => \$cExtensions,
                           "filter_lookahead"    =>
                               \$lcovutil::source_filter_lookahead,
                           "filter_bitwise_conditional" =>
                               \$lcovutil::source_filter_bitwise_are_conditional,
                           "profile"  => \$lcovutil::profile,
                           "parallel" => \$lcovutil::maxParallelism,
                           "memory"   => \$lcovutil::maxMemory,

                           'filter'         => \@rc_filter,
                           'exclude'        => \@rc_exclude_patterns,
                           'include'        => \@rc_include_patterns,
                           'substitute'     => \@rc_subst_patterns,
                           'omit_lines'     => \@rc_omit_patterns,
                           "version_script" => \$lcovutil::extractVersionScript,
                           "checksum"       => \$lcovutil::verify_checksum,
                          });

# Copy related values if not specified
$fn_hi_limit   = $hi_limit if (!defined($fn_hi_limit));
$fn_med_limit  = $med_limit if (!defined($fn_med_limit));
$br_hi_limit   = $hi_limit if (!defined($br_hi_limit));
$br_med_limit  = $med_limit if (!defined($br_med_limit));
$func_coverage = $lcov_func_coverage if (!defined($func_coverage));
$br_coverage   = $lcov_branch_coverage if (!defined($br_coverage));
lcovutil::set_rtl_extensions($rtlExtensions)
    if $rtlExtensions;
lcovutil::set_c_extensions($cExtensions)
    if $cExtensions;

my %unsupported_rc;    # for error checking
my @unsupported_config;
my $keepGoing;
my $quiet = 0;

# Parse command line options
if (!GetOptions("output-directory|o=s" => \$output_directory,
                "tempdir=s"            => \$lcovutil::tmp_dir,
                "header-title=s"       => \$header_title,
                "footer=s"             => \$footer,
                "title|t=s"            => \$test_title,
                "description-file|d=s" => \$desc_filename,
                "keep-descriptions|k"  => \$keep_descriptions,
                "css-file|c=s"         => \$css_filename,
                "baseline-file|b=s"    => \$base_filename,
                "baseline-title=s"     => \$baseline_title,
                "baseline-date=s"      => \$baseline_date,
                "current-date=s"       => \$current_date,
                "diff-file=s"          => \$diff_filename,
                "annotate-script=s"    => \$SourceFile::annotateScript,
                "criteria-script=s"    => \$SummaryInfo::coverageCriteriaScript,
                "version-script=s"     => \$lcovutil::extractVersionScript,
                "checksum"             => \$lcovutil::verify_checksum,
                "new-file-as-baseline" => \$treatNewFileAsBaseline,
                'elide-path-mismatch'  => \$elide_path_mismatch,
                # if 'show-owners' is set: generate the owner table
                #    if it is passed a value: show all the owners,
                #    regardless of whether thay have uncovered code or not
                'show-owners:s'        => \$show_ownerBins,
                'show-noncode'         => \$show_nonCodeOwners,
                'simplified-colors'    => \$show_simplifiedColors,
                "date-bins=s"          => \@datebins,
                "prefix|p=s"           => \@opt_dir_prefix,
                "num-spaces=i"         => \$tab_size,
                "no-prefix"            => \$no_prefix,
                "no-sourceview"        => \$no_sourceview,
                "show-details|s"       => \$show_details,
                "frames|f"             => \$frames,
                "highlight"            => \$highlight,
                "legend"               => \$legend,
                "quiet|q+"             => \$quiet,
                "verbose|v+"           => \$lcovutil::verbose,
                "help|h|?"             => \$help,
                "version"              => \$version,
                "html-prolog=s"        => \$html_prolog_file,
                "html-epilog=s"        => \$html_epilog_file,
                "html-extension=s"     => \$html_ext,
                "html-gzip"            => \$html_gzip,
                "function-coverage"    => \$func_coverage,
                "no-function-coverage" => \$no_func_coverage,
                "branch-coverage"      => \$br_coverage,
                "no-branch-coverage"   => \$no_br_coverage,
                "hierarchical"         => \$hierarchical,
                "sort"                 => \$sort,
                "no-sort"              => \$no_sort,
                "demangle-cpp"         => \$lcovutil::cpp_demangle,
                "ignore-errors=s"      => \@opt_ignore_errors,
                "keep-going"           => \$keepGoing,
                "config-file=s"        => \@unsupported_config,
                "rc=s%"                => \%unsupported_rc,
                "precision=i"          => \$lcovutil::default_precision,
                "missed"               => \$opt_missed,
                "filter=s"             => \@opt_filter,
                "dark-mode"            => \$dark_mode,
                "profile:s"            => \$lcovutil::profile,
                "exclude=s"            => \@lcovutil::exclude_file_patterns,
                "include=s"            => \@lcovutil::include_file_patterns,
                "omit-lines=s"         => \@lcovutil::omit_line_patterns,
                "substitute=s"         => \@lcovutil::file_subst_patterns,
                "parallel|j:i"         => \$lcovutil::maxParallelism,
                "memory=i"             => \$lcovutil::maxMemory,
                "show-navigation"      => \$show_tla,
                "preserve"             => \$lcovutil::preserve_intermediates,
)) {
    print(STDERR "Use $tool_name --help to get usage information\n");
    exit(1);
}
lcovutil::init_verbose_flag($quiet);
@opt_filter                      = @rc_filter unless @opt_filter;
@opt_ignore_errors               = @rc_ignore unless @opt_ignore_errors;
@lcovutil::exclude_file_patterns = @rc_exclude_patterns
    unless @lcovutil::exclude_file_patterns;
@lcovutil::include_file_patterns = @rc_include_patterns
    unless @lcovutil::include_file_patterns;
@lcovutil::subst_file_patterns = @rc_subst_patterns
    unless @lcovutil::subst_file_patterns;
@lcovutil::omit_line_patterns = @rc_omit_patterns
    unless @lcovutil::omit_line_patterns;

$lcovutil::stop_on_error = 0
    if (defined $keepGoing);

@datebins = @rc_datebins unless @datebins;

foreach my $d (['--config-file', scalar(@unsupported_config)],
               ['--rc', scalar(%unsupported_rc)]) {
    die("Error: '" . $d->[0] . "' option name cannot be abbreviated\n")
        if ($d->[1]);
}

# Merge options
$func_coverage = 0
    if ($no_func_coverage);
$br_coverage = 0
    if ($no_br_coverage);
# Merge sort options
$sort = 0
    if ($no_sort);

$show_tla = 1
    if defined($base_filename);
$show_hitTotalCol = !$show_tla || defined($base_filename);
$use_legacyLabels = !defined($base_filename) && $show_tla;
if ($show_tla && !defined($base_filename)) {
    # no baseline - so not a differentialreport.
    #  modify some settings to gnerate corresponding RTL code.
    SummaryInfo::noBaseline();
}

if ($SourceFile::annotateScript) {
    eval {
        require DateTime::Format::W3CDTF;
        DateTime::Format::W3CDTF->import();
    };
    if ($@) {
        lcovutil::ignorable_error($lcovutil::ERROR_PACKAGE,
            "package DateTime::Format::W3CDTF is required to compute code agae when annotations are enabled: $@"
        );
        # OK..user ignored the error - so turn off annotations.
        undef $SourceFile::annotateScript;
    }
}

if ($SourceFile::annotateScript) {
    $show_dateBins = 1;
    if (0 == scalar(@datebins)) {
        # default: 7, 30, 180 days
        @datebins = @SummaryInfo::defaultCutpoints;
    } else {
        my %uniqify = map { $_, 1 } split(/,/, join(',', @datebins));
        @datebins = sort(keys %uniqify);
    }
    SummaryInfo::setAgeGroups(@datebins);
} else {
    $treatNewFileAsBaseline = undef;
    die("\"--show-owners\" option requires \"--annotate-script\" for revision control integration"
    ) if defined($show_ownerBins);
    die("\"--date-bins\" option requires \"--annotate-script\" for revision control integraion"
    ) if (0 != scalar(@datebins));
}
if (0 != (defined($diff_filename) ^ defined($base_filename))) {
    if (defined($base_filename)) {
        warn(
            "specified --baseline-file without --diff-file: assuming no source differences.  Hope that is OK."
        );
    } else {
        die("bare '--diff-file udiff' found.  Must specify '--baseline-file lcovInfoFile' in order to compute differential coverage"
        );
        $diff_filename = undef;
    }
}

lcovutil::init_parallel_params();

if (defined($header_title)) {
    $title = $header_title;
} else {
    # use the default title bar.
    $title =~ s/ differential//   # not a differential report, if no baseline...
        unless defined($base_filename);
}
push(@fileview_prefixes, "-date")
    if ($show_dateBins);
push(@fileview_prefixes, "-owner")
    if (defined($show_ownerBins));

# use LCOV original colors if no baseline file
#  (so no differential coverage)
if ($use_legacyLabels ||
    !$show_tla        ||
    (defined($show_simplifiedColors) &&
        $show_simplifiedColors)
) {
    lcovutil::use_vanilla_color();
}

if ($dark_mode) {
    # if 'dark_mode' is set, then update the color maps
    # For the moment - just reverse the foreground and background
    foreach my $tla (@SummaryInfo::tlaPriorityOrder) {
        # swap
        my $bg = $lcovutil::tlaColor{$tla};
        $lcovutil::tlaColor{$tla}     = $lcovutil::tlaTextColor{$tla};
        $lcovutil::tlaTextColor{$tla} = $bg;
    }
}

@info_filenames = @ARGV;

# Check for help option
if ($help) {
    print_usage(*STDOUT);
    exit(0);
}

# Check for version option
if ($version) {
    print("$tool_name: $lcov_version\n");
    exit(0);
}

# Determine which errors the user wants us to ignore
parse_ignore_errors(@opt_ignore_errors);

# Determine what coverpoints the user wants to filter
parse_cov_filters(@opt_filter);

# Split the list of prefixes if needed
parse_dir_prefix(@opt_dir_prefix);

lcovutil::munge_file_patterns();    # used for exclude/include

# Check for info filename
if (!@info_filenames) {
    die("No filename specified\n" .
        "Use $tool_name --help to get usage information\n");
}

# Generate a title if none is specified
if (!$test_title) {
    if (scalar(@info_filenames) == 1) {
        # Only one filename specified, use it as title
        $test_title = basename($info_filenames[0]);
    } else {
        # More than one filename specified, used default title
        $test_title = "unnamed";
    }
}

if ($base_filename) {
    die("baseline data file '$base_filename' not found")
        unless -e $base_filename;

    if (!$baseline_title) {
        $baseline_title = basename($base_filename);
    }
    my $baseline_create;

    if ($baseline_date) {
        eval {
            my $epoch = Date::Parse::str2time($baseline_date);
            $baseline_create = DateTime->from_epoch(epoch => $epoch);
        };
        if ($@) {
            #did not parse
            info(
                "failed to parse date '$baseline_date' - falling back to file creation time"
            );
        }
    }
    if (!defined($baseline_create)) {
        # if not specified, use 'last modified' of baseline trace file
        my $create = (stat($base_filename))[9];
        $baseline_create = DateTime->from_epoch(epoch => $create);
        $baseline_date   = get_date_string($create)
            unless defined($baseline_date);
    }
    $age_basefile =
        $baseline_create->delta_days(DateTime->now())->in_units('days');
}

# Make sure css_filename is an absolute path (in case we're changing
# directories)
if ($css_filename) {
    if (!($css_filename =~ /^\/(.*)$/)) {
        $css_filename = $cwd . "/" . $css_filename;
    }
}

# Make sure tab_size is within valid range
if ($tab_size < 1) {
    print(STDERR "ERROR: invalid number of spaces specified: $tab_size!\n");
    exit(1);
}

# Get HTML prolog and epilog
$html_prolog = get_html_prolog($html_prolog_file);
$html_epilog = get_html_epilog($html_epilog_file);

# Issue a warning if --no-sourceview is enabled together with --frames
if ($no_sourceview && defined($frames)) {
    warn("WARNING: option --frames disabled because --no-sourceview " .
         "was specified!\n");
    $frames = undef;
}

# Issue a warning if --no-prefix is enabled together with --prefix
if ($no_prefix && @dir_prefix) {
    warn("WARNING: option --prefix disabled because --no-prefix was " .
         "specified!\n");
    @dir_prefix = undef;
}

@fileview_sortlist = ($SORT_FILE);
@funcview_sortlist = ($SORT_FILE);

if ($sort) {
    push(@fileview_sortlist, $SORT_LINE);
    push(@fileview_sortlist, $SORT_FUNC) if ($func_coverage);
    push(@fileview_sortlist, $SORT_BRANCH) if ($br_coverage);
    push(@funcview_sortlist, $SORT_LINE);
}

if ($frames) {
    # Include genpng code needed for overview image generation
    do("$tool_dir/genpng");
}

# Ensure that the c++filt tool is available when using --demangle-cpp
lcovutil::do_mangle_check();

# Make sure precision is within valid range
check_precision();

# Make sure output_directory exists, create it if necessary
if ($output_directory) {
    stat($output_directory);

    if (!-e _) {
        create_sub_dir($output_directory);
    }
}

# Do something
my $now = Time::HiRes::gettimeofday();

gen_html();
my $then = Time::HiRes::gettimeofday();
$lcovutil::profileData{overall} = $then - $now;

my $exit_status = 0;

# now check the coverage criteria (if any)
if (defined($SummaryInfo::coverageCriteriaScript)) {
    # print the criteria summary to stdout:
    #   all criteria fails + any non-empty messages
    # In addtion:  print fails to stderr
    # This way:  Jenkins script can log failure if stderr is not empty
    my $leader = '';
    if ($SummaryInfo::coverageCriteriaStatus != 0) {
        print("Failed coverage criteria:\n");
    } else {
        $leader = "Coverage criteria:\n";
    }
    # sort to print top-level report first, then directories, then files.
    foreach my $name (sort({
                               my $da = $SummaryInfo::coverageCriteria{$a};
                               my $db = $SummaryInfo::coverageCriteria{$b};
                               my $ta = $da->[0];
                               my $tb = $db->[0];
                               return -1 if ($ta eq 'top');
                               return 1 if ($tb eq 'top');
                               if ($ta ne $tb) {
                                   return $ta eq 'file' ? 1 : -1;
                               }
                               $a cmp $b
                           }
                           keys(%SummaryInfo::coverageCriteria))
    ) {
        my $criteria = $SummaryInfo::coverageCriteria{$name};
        next if $criteria->[1] == 0 && 0 == scalar(@{$criteria->[2]});  # passed

        my $msg = $criteria->[0];
        if ($criteria->[0] ne 'top') {
            $msg .= " \"" . $name . "\"";
        }
        $msg .= ": \"" . join(' ', @{$criteria->[2]}) . "\"\n";
        print($leader);
        $leader = '';
        print("  " . $msg);
        if (0 != $criteria->[1]) {
            print(STDERR $msg);
        }
    }
    $exit_status = $SummaryInfo::coverageCriteriaStatus;
}

lcovutil::warn_file_patterns();   # warn about unused include/exclude directives

lcovutil::save_profile("$output_directory/genhtml");

exit($exit_status);

#
# print_usage(handle)
#
# Print usage information.
#

sub print_usage(*)
{
    local *HANDLE = $_[0];

    print(HANDLE <<END_OF_USAGE);
Usage: $tool_name [OPTIONS] INFOFILE(S)

Create HTML output for coverage data found in INFOFILE. Note that INFOFILE
may also be a list of filenames.

Misc:
  -h, --help                        Print this help, then exit
  --version                         Print version number, then exit
  -v, --verbose                     Increment verbosity (for debugging)
  -q, --quiet                       Decrement verbosity (e.g. to not print
                                    progress messages)
      --config-file FILENAME        Specify configuration file location
      --rc SETTING=VALUE            Override configuration file setting
      --ignore-errors ERRORS        Continue after ERRORS (source,unmapped,
                                    empty,category,path,inconsistent,
                                    mismatch,branch,format)
      --keep-going                  Do not stop if error occurs.  Try to
                                    produce a result
      --tempdir dirname             Write temporary and intermediate data here
      --preserve                    Preserve intermediate files (for debugging)

Operation:
  -o, --output-directory OUTDIR     Write HTML output to OUTDIR
  -s, --show-details                Generate detailed directory view
  -d, --description-file DESCFILE   Read test case descriptions from DESCFILE
  -k, --keep-descriptions           Do not remove unused test descriptions
  -b, --baseline-file BASEFILE      Use BASEFILE as baseline file
      --baseline-title STRING       Use STRING a baseline data label in report
      --baseline-date DATE          Use DATE in baseline data label in report
      --current-date DATE           Use DATE in current data label in report
      --annotate-script SCRIPT      Execute SCRIPT to get revision control
                                    history (wraps "git blame" or "p4 annotate")
      --criteria-script SCRIPT      Execute SCRIPT to check coverage criteria
                                    to decide success or failure
      --version-script SCRIPT       Execute SCRIPT to check that source code
                                    version used to generate coverage data matches
                                    version used in display
      --checksum                    Compare source line checksum
      --diff-file UDIFF             unified diff file UDIFF desribes source
                                    code changes between baseline and current
      --elide-path-mismatch         identify matching files if their basename
                                    matches even though dirname does not.
      --show-owners [all]           Show owner summary table. If optional
                                    value provided, show all the owners,
                                    regardless of whether they have uncovered
                                    code or not.
      --show-noncode                Show author in summary table even if none
                                    of their lines are recognized as code.
      --date-bins day[,day,...]     'day' interpreted as integer number of
                                    days, used as upper bound of corresponding
                                    date bin
  -p, --prefix PREFIX               Remove PREFIX from all directory names
      --no-prefix                   Do not remove prefix from directory names
      --(no-)function-coverage      Enable (disable) function coverage display
      --(no-)branch-coverage        Enable (disable) branch coverage display
      --filter FILTERS              FILTERS (branch,line,brace,range,blank,function):
                                    ignore branchcov counts on lines which seem
                                    to have no conditionals
                                    Ignore linecov counts on closing brace
                                    of block, blank, or out-of-range lines
      --include PATTERNS            Display data only for files matching
                                    PATTERNS.
      --exclude PATTERNS            Do not display for files matching PATTERNS.
      --substitute PATTERNS         Munge source file names according to these
                                    Perl regexps (applied in order)
      --omit-lines REGEXP           Ignore coverage data associated with lines
                                    whose content matches regexp.
                                    Perl regexps (applied in order)
  -j, --parallel [INTEGER]          Use at most INTEGER number of parallel
                                    slaves during processing.
      --memory [int_Mb]             Maximum parallel memory consumption - in Mb
      --profile [filename]          Write performance performance statistics
                                    to filename (default is
                                    'output_directory/genhtml.json').

HTML output:
  -f, --frames                      Use HTML frames for source code view
  -t, --title TITLE                 Display TITLE in table header of all pages
  -c, --css-file CSSFILE            Use external style sheet file CSSFILE
      --header-title BANNER         Banner at top of each HTML page
      --footer FOOTER               Footer at bottom of each HTML page
      --no-source                   Do not create source code view
      --num-spaces NUM              Replace tabs with NUM spaces in source view
      --highlight                   Highlight lines with converted-only data
      --legend                      Include color legend in HTML output
      --html-prolog FILE            Use FILE as HTML prolog for generated pages
      --html-epilog FILE            Use FILE as HTML epilog for generated pages
      --html-extension EXT          Use EXT as filename extension for pages
      --html-gzip                   Use gzip to compress HTML
      --(no-)sort                   Enable (disable) sorted coverage views
      --demangle-cpp                Demangle C++ function names
      --precision NUM               Set precision of coverage rate
      --missed                      Show miss counts as negative numbers
      --dark-mode                   Use the dark-mode CSS
      --hierarchical                Generate multilevel HTML report,
                                    matching source code directory structure.
      --show-navigation             Include 'goto first hit/not hit' and
                                    'goto next hit/not hit' hyperlinks in
                                    non-differential source code detail page

For more information see: $lcov_url and\/or the genhtml man page.
END_OF_USAGE

}

#
# print_overall_rate(ln_do, ln_found, ln_hit, fn_do, fn_found, fn_hit, br_do
#                    br_found, br_hit)
#
# Print overall coverage rates for the specified coverage types.
#

sub print_overall_rate($$$$)
{
    my ($ln_do, $fn_do, $br_do, $summary) = @_;

    # use verbosity level -1:  so print unless user says "-q -q"...really quiet
    info(-1, "Overall coverage rate:\n");
    my @types;
    push(@types, 'line') if $ln_do;
    push(@types, 'function') if $fn_do;
    push(@types, 'branch') if $br_do;

    for my $type (@types) {
        my $plural = "ch" eq substr($type, -2, 2) ? "es" : "s";
        info(-1,
             "  $type$plural......: %s\n",
             get_overall_line($summary->get("found", $type),
                              $summary->get("hit", $type),
                              $type));
        if ($main::show_tla) {
            for my $tla (@SummaryInfo::tlaPriorityOrder) {
                my $v = $summary->get($tla, $type);
                my $label =
                    $main::use_legacyLabels ?
                    $SummaryInfo::tlaToLegacySrcLabel{$tla} :
                    $tla;
                info(-1, "       $label...: $v\n")
                    if $v != 0;
            }
        }
    }
    summarize_cov_filters();
}

#
# gen_html()
#
# Generate a set of HTML pages from contents of .info file INFO_FILENAME.
# Files will be written to the current directory. If provided, test case
# descriptions will be read from .tests file TEST_FILENAME and included
# in ouput.
#
# Die on error.
#

sub gen_html()
{
    my $new_info;
    # "Read
    my $readSourceFile = ReadCurrentSource->new();

    # Read in all specified .info files
    my $now = Time::HiRes::gettimeofday();
    foreach (@info_filenames) {
        $new_info =
            TraceFile->load($_, $readSourceFile, $lcovutil::verify_checksum);

        # Combine %new_info with %current_data
        $current_data->append_tracefile($new_info);
    }
    my $then = Time::HiRes::gettimeofday();
    $lcovutil::profileData{parse_current} = $then - $now;

    info("Found %d entries.\n", scalar($current_data->files()));

    # Read and apply diff data if specified - need this before we
    #  try to read and process the baseline..
    if ($diff_filename) {
        $now = Time::HiRes::gettimeofday();
        info("Reading diff file $diff_filename\n");
        $diff_data->load($diff_filename);
        $then = Time::HiRes::gettimeofday();
        $lcovutil::profileData{parse_diff} = $then - $now;
    }

    # Read and apply baseline data if specified
    if ($base_filename) {
        $now = Time::HiRes::gettimeofday();
        my $readBaseSource = ReadBaselineSource->new($diff_data);
        $then = Time::HiRes::gettimeofday();
        $lcovutil::profileData{parse_source} = $then - $now;
        # Read baseline file

        $now = Time::HiRes::gettimeofday();
        info("Reading baseline file $base_filename\n");
        $new_info = TraceFile->load($base_filename, $readBaseSource,
                                    $lcovutil::verify_checksum);
        $base_data->append_tracefile($new_info);
        info("Found %d baseline entries.\n", scalar($base_data->files()));
        $then = Time::HiRes::gettimeofday();
        $lcovutil::profileData{parse_baseline} = $then - $now;
    }

    if ($diff_filename) {
        # check for files which appear in the udiff but which dont appear
        # in either the current or baseline trace data.  Those may be
        # mapping issues - different pathname in .info file vs udiff
        if (!$diff_data->check_path_consistency($base_data, $current_data)) {
            lcovutil::ignorable_error($ERROR_INCONSISTENT_PATH,
                  "possible path inconsistency in baseline/current/udiff data");
        }
    }

    if ($no_prefix) {
        # User requested that we leave filenames alone
        info("User asked not to remove filename prefix\n");
    } elsif (!@dir_prefix) {
        # Get prefix common to most directories in list
        my $prefix = get_prefix(1, $current_data->files());

        if ($prefix) {
            info("Found common filename prefix \"$prefix\"\n");
            $dir_prefix[0] = $prefix;
        } else {
            info("No common filename prefix found!\n");
            $no_prefix = 1;
        }
    } else {
        my $msg = "Using user-specified filename prefix ";
        for my $i (0 .. $#dir_prefix) {
            $dir_prefix[$i] =~ s/\/+$//;
            $msg .= ", " unless 0 == $i;
            $msg .= "\"" . $dir_prefix[$i] . "\"";
        }
        info($msg . "\n");
    }

    # Read in test description file if specified
    if ($desc_filename) {
        info("Reading test description file $desc_filename\n");
        %test_description = %{read_testfile($desc_filename)};

        # Remove test descriptions which are not referenced
        # from %current_data if user didn't tell us otherwise
        if (!$keep_descriptions) {
            remove_unused_descriptions();
        }
    }

    # Change to output directory if specified
    if ($output_directory) {
        foreach my $s (\$SourceFile::annotateScript,
                       \$SummaryInfo::coverageCriteriaScript,
                       \$lcovutil::extractVersionScript
        ) {
            # if any of the scripts use relative paths, then turn them into
            #  absolute paths - so they continue to work correctly after we 'cd'
            if (defined($$s)) {
                chomp($$s);
                my @scr = split(' ', $$s);
                if (!File::Spec->file_name_is_absolute($scr[0])) {
                    $scr[0] = File::Spec->rel2abs($scr[0]);
                    $$s = join(' ', @scr);
                }
            }
        }
        chdir($output_directory) or
            die("ERROR: cannot change to directory " . "$output_directory!\n");
    }

    info("Writing .css and .png files.\n");
    write_css_file();
    write_png_files();

    if ($html_gzip) {
        info("Writing .htaccess file.\n");
        write_htaccess_file();
    }

    info("Generating output.\n");

    my $genhtml = GenHtml->new($current_data);

    # Check if there are any test case descriptions to write out
    if (%test_description) {
        info("Writing test case description file.\n");
        write_description_file(\%test_description, $genhtml->top());
    }

    print_overall_rate(1, $func_coverage, $br_coverage, $genhtml->top());

    chdir($cwd);
}

#
# html_create(handle, filename)
#

sub html_create($$)
{
    my $handle   = $_[0];
    my $filename = $_[1];

    if ($html_gzip) {
        open($handle, "|-", "gzip -c >'$filename'") or
            die("ERROR: cannot open $filename for writing (gzip)!\n");
    } else {
        open($handle, ">", $filename) or
            die("ERROR: cannot open $filename for writing!\n");
    }
}

# $ctrls = [$view_type, $sort_type, $bin_prefix]
# $perTestcaseResult = [\%line, \%func, \%branch]
#sub write_dir_page($$$$$$$;$)
sub write_dir_page
{
    my ($ctrls, $page_suffix, $title, $rel_dir, $base_dir, $trunc_dir,
        $summary, $perTestcaseResult)
        = @_;

    my $bin_prefix = $ctrls->[3];
    # Generate directory overview page including details
    html_create(*HTML_HANDLE,
                "$rel_dir/index$bin_prefix$page_suffix.$html_ext");
    if (!defined($trunc_dir)) {
        $trunc_dir = "";
    }
    $title .= " - " if ($trunc_dir ne "");
    write_html_prolog(*HTML_HANDLE, $base_dir, "LCOV - $title$trunc_dir");
    write_header(*HTML_HANDLE, $ctrls, $trunc_dir, $rel_dir, $summary, undef);
    write_file_table(*HTML_HANDLE, $base_dir, $perTestcaseResult,
                     $summary, $ctrls);
    write_html_epilog(*HTML_HANDLE, $base_dir);
    close(*HTML_HANDLE);
}

sub write_summary_pages($$$$$$$$)
{
    my ($name, $summaryType, $summary, $show_details,
        $rel_dir, $base_dir, $trunc_dir, $testhashes) = @_;

    my $start = Time::HiRes::gettimeofday();
    my @summaryBins;
    push(@summaryBins, 'owner') if defined($main::show_ownerBins);
    push(@summaryBins, 'date') if defined($main::show_dateBins);

    my @dirPageCalls;
    foreach my $sort_type (@main::fileview_sortlist) {
        my @ctrls = ($summaryType,    # 1 == 'list files'
                     "name",          # primary key
                     $sort_type, "");
        my $sort_str = $main::fileview_sortname[$sort_type];
        foreach my $bin_prefix (@main::fileview_prefixes) {
            # Generate directory overview page (without details)
            # no per-testcase data in this page...
            $ctrls[3] = $bin_prefix;
            # need copy because we are calling multiple child processes
            my @copy = @ctrls;
            push(@dirPageCalls,
                 [\@copy, $sort_str, $test_title, $rel_dir,
                  $base_dir, $trunc_dir, $summary
                 ]);

            if ($show_details) {
                # Generate directory overview page including details
                push(@dirPageCalls,
                     [\@copy, "-detail" . $sort_str,
                      $test_title, $rel_dir,
                      $base_dir, $trunc_dir,
                      $summary, $testhashes
                     ]);
            }
        }
        $ctrls[3] = "";    # no bin...
        foreach my $primary_key (@summaryBins) {
            $ctrls[1] = $primary_key;
            my @copy = @ctrls;
            push(@dirPageCalls,
                 [\@copy, '-bin_' . $primary_key . $sort_str,
                  $test_title, $rel_dir, $base_dir, $trunc_dir, $summary
                 ]);
        }
    }

    foreach my $params (@dirPageCalls) {
        write_dir_page(@$params);
    }
    my $end = Time::HiRes::gettimeofday();
    $lcovutil::profileData{html}{$name} = $end - $start;
}

sub write_function_page($$$$$$$$$$$$$)
{
    my ($fileCovInfo, $base_dir, $rel_dir, $trunc_dir, $base_name,
        $title, $sumcount, $funcdata, $testfncdata, $sumbrcount,
        $testbrdata, $sort_type, $summary) = @_;
    my $pagetitle;
    my $filename;

    # Generate function table for this file
    if ($sort_type == 0) {
        $filename = "$rel_dir/$base_name.func.$html_ext";
    } else {
        $filename = "$rel_dir/$base_name.func-sort-c.$html_ext";
    }
    html_create(*HTML_HANDLE, $filename);
    $pagetitle = "LCOV - $title - $trunc_dir/$base_name - functions";
    write_html_prolog(*HTML_HANDLE, $base_dir, $pagetitle);
    write_header(*HTML_HANDLE, [4, 'name', $sort_type,],
                 "$trunc_dir/$base_name", "$rel_dir/$base_name", $summary,
                 undef);
    write_function_table(*HTML_HANDLE, $fileCovInfo,
                         "$base_name.gcov.$html_ext", $sumcount,
                         $funcdata, $testfncdata,
                         $sumbrcount, $testbrdata,
                         $base_name, $base_dir,
                         $sort_type);
    write_html_epilog(*HTML_HANDLE, $base_dir, 1);
    close(*HTML_HANDLE);
}

#
# process_file(parent_dir_summary, trunc_dir, rel_dir, filename)
#

sub process_file($$$$$)
{
    my ($fileSummary, $parent_dir_summary, $trunc_dir, $rel_dir, $filename) =
        @_;
    my $trunc_name = apply_prefix($filename, @dir_prefix);
    info("Processing file $trunc_name\n");

    my $base_name = basename($filename);
    my $base_dir  = get_relative_base_path($rel_dir);
    my @source;
    my $pagetitle;
    local *HTML_HANDLE;

    my ($testdata, $sumcount, $funcdata, $checkdata, $testfncdata,
        $testbrdata, $sumbrcount, $lines_found, $lines_hit, $fn_found,
        $fn_hit, $br_found, $br_hit
    ) = $current_data->data($filename)->get_info();

    $fileSummary->l_found($lines_found);
    $fileSummary->l_hit($lines_hit);

    $fileSummary->f_found($fn_found);
    $fileSummary->f_hit($fn_hit);

    $fileSummary->b_found($br_found);
    $fileSummary->b_hit($br_hit);

    # handle case that file was moved between baseline and current
    my $baseline_filename = $diff_data->baseline_file_name($filename);
    # when looking up the baseline file, handle the case that the
    #  pathname does not match exactly - see comment in TraceFile::data
    my $fileBase    = $base_data->data($baseline_filename, 1);
    my $fileCurrent = $current_data->data($filename);
    # build coverage differential categories
    my $now = Time::HiRes::gettimeofday();
    my $fileCovInfo =
        FileCoverageInfo->new($filename, $fileBase, $fileCurrent, $diff_data
                                  #, scalar($filename =~ /vcsapi_type/ # verbose
        );
    my $then = Time::HiRes::gettimeofday();
    $lcovutil::profileData{categorize}{$filename} = $then - $now;

    info("  lines=" . $lines_found . " hit=" . $lines_hit . "\n");

    my $fileHasNoBaselineInfo =
        ($fileBase->is_empty() &&
         $main::treatNewFileAsBaseline &&
         defined($main::base_filename));
    # if this file is older than the baseline and there is no associated
    #   baseline data - then it appears to have been added to the build
    #   recently
    # We want to treat the code as "CBC" or "UBC" (not "GIC" and "UIC")
    #   because we only just turned section "on" - and we don't want the
    #   coverage ratchet to fail the build if UIC is nonzero

    # NOTE:  SourceFile constructor modifies some input data:
    #   - $fileSummary struct is also modified: update total counts in
    #     each bucket, counts in each date range
    #   - $fileCovInfo: change GIC->CBC, UIC->UBC if $fineNotInBaseline and
    #     source code is older than baseline file
    my $srcfile = SourceFile->new($filename, $fileSummary, $fileCovInfo,
                                  $sumcount, $fileHasNoBaselineInfo);
    # somewhat of a hack:  we are ultimately going to merge $fileSummary
    #   (the data for this particular file) into $parent_dir (the data
    #    for the parent directory) - but we need to do that in the caller
    #    (because we are building $fileSummary in a child process that we are
    #    going to pass back.  But we also use the parent and its name
    #    in HTML generation...
    #    we clear this setting before we return the generated summary
    $fileSummary->setParent($parent_dir_summary);

    my $from = Time::HiRes::gettimeofday();
    # Return after this point in case user asked us not to generate
    # source code view
    if (!$no_sourceview) {
        # Generate source code view for this file
        html_create(*HTML_HANDLE, "$rel_dir/$base_name.gcov.$html_ext");
        $pagetitle = "LCOV - $test_title - $trunc_dir/$base_name";
        write_html_prolog(*HTML_HANDLE, $base_dir, $pagetitle);
        write_header(*HTML_HANDLE, [2, 'name', 0],
                     "$trunc_dir/$base_name",
                     "$rel_dir/$base_name", $fileSummary, $srcfile);

        @source = write_source(*HTML_HANDLE, $srcfile, $sumcount,
                               $checkdata, $fileCovInfo, $funcdata,
                               $sumbrcount);

        write_html_epilog(*HTML_HANDLE, $base_dir, 1);
        close(*HTML_HANDLE);

        if ($func_coverage) {
            # Create function tables
            my $lineCovMap = $fileCovInfo->lineMap();
            # simply map between function leader name and differential data
            my $differentialMap = $fileCovInfo->functionMap();

            foreach (@funcview_sortlist) {
                write_function_page($differentialMap, $base_dir,
                                    $rel_dir, $trunc_dir,
                                    $base_name, $test_title,
                                    $sumcount, $funcdata,
                                    $testfncdata, $sumbrcount,
                                    $testbrdata, $_,
                                    $fileSummary);
            }
        }

        # Additional files are needed in case of frame output
        if ($frames) {
            # Create overview png file
            my $simplified = defined($main::show_simplifiedColors) &&
                $main::show_simplifiedColors;
            gen_png("$rel_dir/$base_name.gcov.png",
                    $main::show_tla && !$simplified,
                    $main::dark_mode,
                    $overview_width,
                    $tab_size,
                    @source);

            # Create frameset page
            html_create(*HTML_HANDLE,
                        "$rel_dir/$base_name.gcov.frameset.$html_ext");
            write_frameset(*HTML_HANDLE, $base_dir, $base_name, $pagetitle);
            close(*HTML_HANDLE);

            # Write overview frame
            html_create(*HTML_HANDLE,
                        "$rel_dir/$base_name.gcov.overview.$html_ext");
            write_overview(*HTML_HANDLE, $base_dir, $base_name,
                           $pagetitle, scalar(@source));
            close(*HTML_HANDLE);
        }
    }
    my $to = Time::HiRes::gettimeofday();
    $lcovutil::profileData{html}{$filename} = $to - $from;
    return ($testdata, $testfncdata, $testbrdata);
}

#
# get_prefix(min_dir, filename_list)
#
# Search FILENAME_LIST for a directory prefix which is common to as many
# list entries as possible, so that removing this prefix will minimize the
# sum of the lengths of all resulting shortened filenames while observing
# that no filename has less than MIN_DIR parent directories.
#

sub get_prefix($@)
{

    my ($min_dir, @filename_list) = @_;
    my %prefix;     # mapping: prefix -> sum of lengths
    my $current;    # Temporary iteration variable

    # Find list of prefixes
    foreach (@filename_list) {
        # Need explicit assignment to get a copy of $_ so that
        # shortening the contained prefix does not affect the list
        $current = $_;
        while ($current = shorten_prefix($current)) {
            $current .= "/";

            # Skip rest if the remaining prefix has already been
            # added to hash
            if (exists($prefix{$current})) { last; }

            # Initialize with 0
            $prefix{$current} = "0";
        }

    }

    # Remove all prefixes that would cause filenames to have less than
    # the minimum number of parent directories
    foreach my $filename (@filename_list) {
        my $dir = dirname($filename);

        for (my $i = 0; $i < $min_dir; $i++) {
            delete($prefix{$dir . "/"});
            $dir = shorten_prefix($dir);
        }
    }

    # Check if any prefix remains
    return undef if (!%prefix);

    # Calculate sum of lengths for all prefixes
    foreach $current (keys(%prefix)) {
        foreach (@filename_list) {
            # Add original length
            $prefix{$current} += length($_);

            # Check whether prefix matches
            if (substr($_, 0, length($current)) eq $current) {
                # Subtract prefix length for this filename
                $prefix{$current} -= length($current);
            }
        }
    }

    # Find and return prefix with minimal sum
    $current = (keys(%prefix))[0];

    foreach (keys(%prefix)) {
        if ($prefix{$_} < $prefix{$current}) {
            $current = $_;
        }
    }

    $current =~ s/\/$//;

    return ($current);
}

#
# shorten_prefix(prefix)
#
# Return PREFIX shortened by last directory component.
#

sub shorten_prefix($)
{
    my @list = split("/", $_[0]);

    pop(@list);
    return join("/", @list);
}

#
# get_relative_base_path(subdirectory)
#
# Return a relative path string which references the base path when applied
# in SUBDIRECTORY.
#
# Example: get_relative_base_path("fs/mm") -> "../../"
#

sub get_relative_base_path($)
{
    my $result = "";
    my $index;

    # Make an empty directory path a special case
    if (!$_[0]) { return (""); }

    # Count number of /s in path
    $index = ($_[0] =~ s/\//\//g);

    # Add a ../ to $result for each / in the directory path + 1
    for (; $index >= 0; $index--) {
        $result .= "../";
    }

    return $result;
}

#
# read_testfile(test_filename)
#
# Read in file TEST_FILENAME which contains test descriptions in the format:
#
#   TN:<whitespace><test name>
#   TD:<whitespace><test description>
#
# for each test case. Return a reference to a hash containing a mapping
#
#   test name -> test description.
#
# Die on error.
#

sub read_testfile($)
{
    my %result;
    my $test_name;
    my $changed_testname;
    local *TEST_HANDLE;

    open(TEST_HANDLE, "<", $_[0]) or
        die("ERROR: cannot open $_[0]!\n");

    while (<TEST_HANDLE>) {
        chomp($_);
        s/\r//g;
        # Match lines beginning with TN:<whitespace(s)>
        if (/^TN:\s+(.*?)\s*$/) {
            # Store name for later use
            $test_name = $1;
            if ($test_name =~ s/\W/_/g) {
                $changed_testname = 1;
            }
        }

        # Match lines beginning with TD:<whitespace(s)>
        if (/^TD:\s+(.*?)\s*$/) {
            if (!defined($test_name)) {
                die("ERROR: Found test description without prior test name in $_[0]:$.\n"
                );
            }
            # Check for empty line
            if ($1) {
                # Add description to hash
                $result{$test_name} .= " $1";
            } else {
                # Add empty line
                $result{$test_name} .= "\n\n";
            }
        }
    }

    close(TEST_HANDLE);

    if ($changed_testname) {
        warn("WARNING: invalid characters removed from testname in " .
             "descriptions file $_[0]\n");
    }

    return \%result;
}

#
# escape_html(STRING)
#
# Return a copy of STRING in which all occurrences of HTML special characters
# are escaped.
#

sub escape_html($)
{
    my $string = $_[0];

    if (!$string) { return ""; }

    $string =~ s/&/&amp;/g;      # & -> &amp;
    $string =~ s/</&lt;/g;       # < -> &lt;
    $string =~ s/>/&gt;/g;       # > -> &gt;
    $string =~ s/\"/&quot;/g;    # " -> &quot;

    while ($string =~ /^([^\t]*)(\t)/) {
        my $replacement = " " x ($tab_size - (length($1) % $tab_size));
        $string =~ s/^([^\t]*)(\t)/$1$replacement/;
    }

    $string =~ s/\n/<br>/g;      # \n -> <br>

    return $string;
}

#
# get_date_string()
#
# Return the current date in the form: yyyy-mm-dd
#

sub get_date_string($)
{
    my $time = $_[0];
    my @timeresult;

    if (!$time) {
        if (defined $ENV{'SOURCE_DATE_EPOCH'}) {
            @timeresult = gmtime($ENV{'SOURCE_DATE_EPOCH'});
        } else {
            @timeresult = localtime();
        }
    } else {
        @timeresult = localtime($time);
    }
    my ($year, $month, $day, $hour, $min, $sec) = @timeresult[5, 4, 3, 2, 1, 0];

    return
        sprintf("%d-%02d-%02d %02d:%02d:%02d",
                $year + 1900,
                $month + 1, $day, $hour, $min, $sec);
}

#
# create_sub_dir(dir_name)
#
# Create subdirectory DIR_NAME if it does not already exist, including all its
# parent directories.
#
# Die on error.
#

sub create_sub_dir($)
{
    my ($dir) = @_;

    system("mkdir", "-p", $dir) and
        die("ERROR: cannot create directory $dir!\n");
}

#
# write_description_file(descriptions, overall_found, overall_hit,
#                        total_fn_found, total_fn_hit, total_br_found,
#                        total_br_hit)
#
# Write HTML file containing all test case descriptions. DESCRIPTIONS is a
# reference to a hash containing a mapping
#
#   test case name -> test case description
#
# Die on error.
#

sub write_description_file($$)
{
    my %description = %{$_[0]};
    my $summary     = $_[1];
    my $test_name;
    local *HTML_HANDLE;

    html_create(*HTML_HANDLE, "descriptions.$html_ext");
    write_html_prolog(*HTML_HANDLE, "", "LCOV - test case descriptions");
    write_header(*HTML_HANDLE, [3, 'name', 0], "", "", $summary, undef);

    write_test_table_prolog(*HTML_HANDLE,
                            "Test case descriptions - alphabetical list");

    foreach $test_name (sort(keys(%description))) {
        my $desc = $description{$test_name};

        $desc = escape_html($desc) if (!$rc_desc_html);
        write_test_table_entry(*HTML_HANDLE, $test_name, $desc);
    }

    write_test_table_epilog(*HTML_HANDLE);
    write_html_epilog(*HTML_HANDLE, "");

    close(*HTML_HANDLE);
}

#
# write_png_files()
#
# Create all necessary .png files for the HTML-output in the current
# directory. .png-files are used as bar graphs.
#
# Die on error.
#

sub write_png_files()
{
    my %data;
    local *PNG_HANDLE;

    $data{"ruby.png"} =
        $dark_mode ?
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
         0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
         0x00, 0x00, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x25,
         0xdb, 0x56, 0xca, 0x00, 0x00, 0x00, 0x06, 0x50, 0x4c, 0x54,
         0x45, 0x80, 0x1b, 0x18, 0x00, 0x00, 0x00, 0x39, 0x4a, 0x74,
         0xf4, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54, 0x08,
         0xd7, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0xe2,
         0x21, 0xbc, 0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
         0x44, 0xae, 0x42, 0x60, 0x82
        ] :
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
         0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
         0x00, 0x00, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x25,
         0xdb, 0x56, 0xca, 0x00, 0x00, 0x00, 0x07, 0x74, 0x49, 0x4d,
         0x45, 0x07, 0xd2, 0x07, 0x11, 0x0f, 0x18, 0x10, 0x5d, 0x57,
         0x34, 0x6e, 0x00, 0x00, 0x00, 0x09, 0x70, 0x48, 0x59, 0x73,
         0x00, 0x00, 0x0b, 0x12, 0x00, 0x00, 0x0b, 0x12, 0x01, 0xd2,
         0xdd, 0x7e, 0xfc, 0x00, 0x00, 0x00, 0x04, 0x67, 0x41, 0x4d,
         0x41, 0x00, 0x00, 0xb1, 0x8f, 0x0b, 0xfc, 0x61, 0x05, 0x00,
         0x00, 0x00, 0x06, 0x50, 0x4c, 0x54, 0x45, 0xff, 0x35, 0x2f,
         0x00, 0x00, 0x00, 0xd0, 0x33, 0x9a, 0x9d, 0x00, 0x00, 0x00,
         0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x00,
         0x00, 0x00, 0x02, 0x00, 0x01, 0xe5, 0x27, 0xde, 0xfc, 0x00,
         0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60,
         0x82
        ];

    $data{"amber.png"} =
        $dark_mode ?
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
         0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
         0x00, 0x00, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x25,
         0xdb, 0x56, 0xca, 0x00, 0x00, 0x00, 0x06, 0x50, 0x4c, 0x54,
         0x45, 0x99, 0x86, 0x30, 0x00, 0x00, 0x00, 0x51, 0x83, 0x43,
         0xd7, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54, 0x08,
         0xd7, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0xe2,
         0x21, 0xbc, 0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
         0x44, 0xae, 0x42, 0x60, 0x82
        ] :
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
         0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
         0x00, 0x00, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x25,
         0xdb, 0x56, 0xca, 0x00, 0x00, 0x00, 0x07, 0x74, 0x49, 0x4d,
         0x45, 0x07, 0xd2, 0x07, 0x11, 0x0f, 0x28, 0x04, 0x98, 0xcb,
         0xd6, 0xe0, 0x00, 0x00, 0x00, 0x09, 0x70, 0x48, 0x59, 0x73,
         0x00, 0x00, 0x0b, 0x12, 0x00, 0x00, 0x0b, 0x12, 0x01, 0xd2,
         0xdd, 0x7e, 0xfc, 0x00, 0x00, 0x00, 0x04, 0x67, 0x41, 0x4d,
         0x41, 0x00, 0x00, 0xb1, 0x8f, 0x0b, 0xfc, 0x61, 0x05, 0x00,
         0x00, 0x00, 0x06, 0x50, 0x4c, 0x54, 0x45, 0xff, 0xe0, 0x50,
         0x00, 0x00, 0x00, 0xa2, 0x7a, 0xda, 0x7e, 0x00, 0x00, 0x00,
         0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x00,
         0x00, 0x00, 0x02, 0x00, 0x01, 0xe5, 0x27, 0xde, 0xfc, 0x00,
         0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60,
         0x82
        ];
    $data{"emerald.png"} =
        $dark_mode ?
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
         0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
         0x00, 0x00, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x25,
         0xdb, 0x56, 0xca, 0x00, 0x00, 0x00, 0x06, 0x50, 0x4c, 0x54,
         0x45, 0x00, 0x66, 0x00, 0x0a, 0x0a, 0x0a, 0xa4, 0xb8, 0xbf,
         0x60, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54, 0x08,
         0xd7, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0xe2,
         0x21, 0xbc, 0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
         0x44, 0xae, 0x42, 0x60, 0x82
        ] :
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
         0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
         0x00, 0x00, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x25,
         0xdb, 0x56, 0xca, 0x00, 0x00, 0x00, 0x07, 0x74, 0x49, 0x4d,
         0x45, 0x07, 0xd2, 0x07, 0x11, 0x0f, 0x22, 0x2b, 0xc9, 0xf5,
         0x03, 0x33, 0x00, 0x00, 0x00, 0x09, 0x70, 0x48, 0x59, 0x73,
         0x00, 0x00, 0x0b, 0x12, 0x00, 0x00, 0x0b, 0x12, 0x01, 0xd2,
         0xdd, 0x7e, 0xfc, 0x00, 0x00, 0x00, 0x04, 0x67, 0x41, 0x4d,
         0x41, 0x00, 0x00, 0xb1, 0x8f, 0x0b, 0xfc, 0x61, 0x05, 0x00,
         0x00, 0x00, 0x06, 0x50, 0x4c, 0x54, 0x45, 0x1b, 0xea, 0x59,
         0x0a, 0x0a, 0x0a, 0x0f, 0xba, 0x50, 0x83, 0x00, 0x00, 0x00,
         0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x00,
         0x00, 0x00, 0x02, 0x00, 0x01, 0xe5, 0x27, 0xde, 0xfc, 0x00,
         0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60,
         0x82
        ];
    $data{"snow.png"} =
        $dark_mode ?
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
         0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
         0x00, 0x00, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x25,
         0xdb, 0x56, 0xca, 0x00, 0x00, 0x00, 0x06, 0x50, 0x4c, 0x54,
         0x45, 0xdd, 0xdd, 0xdd, 0x00, 0x00, 0x00, 0xae, 0x9c, 0x6c,
         0x92, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54, 0x08,
         0xd7, 0x63, 0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0xe2,
         0x21, 0xbc, 0x33, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
         0x44, 0xae, 0x42, 0x60, 0x82
        ] :
        [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
         0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01,
         0x00, 0x00, 0x00, 0x01, 0x01, 0x03, 0x00, 0x00, 0x00, 0x25,
         0xdb, 0x56, 0xca, 0x00, 0x00, 0x00, 0x07, 0x74, 0x49, 0x4d,
         0x45, 0x07, 0xd2, 0x07, 0x11, 0x0f, 0x1e, 0x1d, 0x75, 0xbc,
         0xef, 0x55, 0x00, 0x00, 0x00, 0x09, 0x70, 0x48, 0x59, 0x73,
         0x00, 0x00, 0x0b, 0x12, 0x00, 0x00, 0x0b, 0x12, 0x01, 0xd2,
         0xdd, 0x7e, 0xfc, 0x00, 0x00, 0x00, 0x04, 0x67, 0x41, 0x4d,
         0x41, 0x00, 0x00, 0xb1, 0x8f, 0x0b, 0xfc, 0x61, 0x05, 0x00,
         0x00, 0x00, 0x06, 0x50, 0x4c, 0x54, 0x45, 0xff, 0xff, 0xff,
         0x00, 0x00, 0x00, 0x55, 0xc2, 0xd3, 0x7e, 0x00, 0x00, 0x00,
         0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x00,
         0x00, 0x00, 0x02, 0x00, 0x01, 0xe5, 0x27, 0xde, 0xfc, 0x00,
         0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60,
         0x82
        ];

    $data{"glass.png"} = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
                          0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
                          0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
                          0x01, 0x03, 0x00, 0x00, 0x00, 0x25, 0xdb, 0x56,
                          0xca, 0x00, 0x00, 0x00, 0x04, 0x67, 0x41, 0x4d,
                          0x41, 0x00, 0x00, 0xb1, 0x8f, 0x0b, 0xfc, 0x61,
                          0x05, 0x00, 0x00, 0x00, 0x06, 0x50, 0x4c, 0x54,
                          0x45, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x55,
                          0xc2, 0xd3, 0x7e, 0x00, 0x00, 0x00, 0x01, 0x74,
                          0x52, 0x4e, 0x53, 0x00, 0x40, 0xe6, 0xd8, 0x66,
                          0x00, 0x00, 0x00, 0x01, 0x62, 0x4b, 0x47, 0x44,
                          0x00, 0x88, 0x05, 0x1d, 0x48, 0x00, 0x00, 0x00,
                          0x09, 0x70, 0x48, 0x59, 0x73, 0x00, 0x00, 0x0b,
                          0x12, 0x00, 0x00, 0x0b, 0x12, 0x01, 0xd2, 0xdd,
                          0x7e, 0xfc, 0x00, 0x00, 0x00, 0x07, 0x74, 0x49,
                          0x4d, 0x45, 0x07, 0xd2, 0x07, 0x13, 0x0f, 0x08,
                          0x19, 0xc4, 0x40, 0x56, 0x10, 0x00, 0x00, 0x00,
                          0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63,
                          0x60, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x48,
                          0xaf, 0xa4, 0x71, 0x00, 0x00, 0x00, 0x00, 0x49,
                          0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
    ];

    if ($sort) {
        $data{"updown.png"} =
            $dark_mode ?
            [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
             0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x0a,
             0x00, 0x00, 0x00, 0x0e, 0x08, 0x06, 0x00, 0x00, 0x00, 0x16,
             0xa3, 0x8d, 0xab, 0x00, 0x00, 0x00, 0x43, 0x49, 0x44, 0x41,
             0x54, 0x28, 0xcf, 0x63, 0x60, 0x40, 0x03, 0x77, 0xef, 0xde,
             0xfd, 0x7f, 0xf7, 0xee, 0xdd, 0xff, 0xe8, 0xe2, 0x8c, 0xe8,
             0x8a, 0x90, 0xf9, 0xca, 0xca, 0xca, 0x8c, 0x18, 0x0a, 0xb1,
             0x99, 0x82, 0xac, 0x98, 0x11, 0x9f, 0x22, 0x64, 0xc5, 0x8c,
             0x84, 0x14, 0xc1, 0x00, 0x13, 0xc3, 0x80, 0x01, 0xea, 0xbb,
             0x91, 0xf8, 0xe0, 0x21, 0x29, 0xc0, 0x89, 0x89, 0x42, 0x06,
             0x62, 0x13, 0x05, 0x00, 0xe1, 0xd3, 0x2d, 0x91, 0x93, 0x15,
             0xa4, 0xb2, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44,
             0xae, 0x42, 0x60, 0x82
            ] :
            [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00,
             0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x0a,
             0x00, 0x00, 0x00, 0x0e, 0x08, 0x06, 0x00, 0x00, 0x00, 0x16,
             0xa3, 0x8d, 0xab, 0x00, 0x00, 0x00, 0x3c, 0x49, 0x44, 0x41,
             0x54, 0x28, 0xcf, 0x63, 0x60, 0x40, 0x03, 0xff, 0xa1, 0x00,
             0x5d, 0x9c, 0x11, 0x5d, 0x11, 0x8a, 0x24, 0x23, 0x23, 0x23,
             0x86, 0x42, 0x6c, 0xa6, 0x20, 0x2b, 0x66, 0xc4, 0xa7, 0x08,
             0x59, 0x31, 0x23, 0x21, 0x45, 0x30, 0xc0, 0xc4, 0x30, 0x60,
             0x80, 0xfa, 0x6e, 0x24, 0x3e, 0x78, 0x48, 0x0a, 0x70, 0x62,
             0xa2, 0x90, 0x81, 0xd8, 0x44, 0x01, 0x00, 0xe9, 0x5c, 0x2f,
             0xf5, 0xe2, 0x9d, 0x0f, 0xf9, 0x00, 0x00, 0x00, 0x00, 0x49,
             0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82
            ];
    }

    foreach (keys(%data)) {
        open(PNG_HANDLE, ">", $_) or
            die("ERROR: cannot create $_!\n");
        binmode(PNG_HANDLE);
        print(PNG_HANDLE map(chr, @{$data{$_}}));
        close(PNG_HANDLE);
    }
}

#
# write_htaccess_file()
#

sub write_htaccess_file()
{
    local *HTACCESS_HANDLE;
    my $htaccess_data;

    open(*HTACCESS_HANDLE, ">", ".htaccess") or
        die("ERROR: cannot open .htaccess for writing!\n");

    $htaccess_data = (<<"END_OF_HTACCESS")
AddEncoding x-gzip .html
END_OF_HTACCESS
        ;

    print(HTACCESS_HANDLE $htaccess_data);
    close(*HTACCESS_HANDLE);
}

#
# write_css_file()
#
# Write the cascading style sheet file gcov.css to the current directory.
# This file defines basic layout attributes of all generated HTML pages.
#

sub write_css_file()
{
    local *CSS_HANDLE;

    # Check for a specified external style sheet file
    if ($css_filename) {
        # Simply copy that file
        system("cp", $css_filename, "gcov.css") and
            die("ERROR: cannot copy file $css_filename!\n");
        return;
    }

    open(CSS_HANDLE, ">", "gcov.css") or
        die("ERROR: cannot open gcov.css for writing!\n");

    # *************************************************************

    # *************************************************************
    my $ownerBackground = "#COLOR_17";            # very light pale grey/blue
    my $ownerCovHi      = "#COLOR_18";            # light green
    my $ownerCovMed     = "#COLOR_19";            # light yellow
    my $ownerCovLo      = "#COLOR_20";            # lighter red
    my $css_data        = ($_ = <<"END_OF_CSS")
        /* All views: initial background and text color */
        body
        {
          color: #COLOR_00;
          background-color: #COLOR_14;
        }

        /* All views: standard link format*/
        a:link
        {
          color: #COLOR_15;
          text-decoration: underline;
        }

        /* All views: standard link - visited format */
        a:visited
        {
          color: #COLOR_01;
          text-decoration: underline;
        }

        /* All views: standard link - activated format */
        a:active
        {
          color: #COLOR_11;
          text-decoration: underline;
        }

        /* All views: main title format */
        td.title
        {
          text-align: center;
          padding-bottom: 10px;
          font-family: sans-serif;
          font-size: 20pt;
          font-style: italic;
          font-weight: bold;
        }
        /* "Line coverage date bins" leader */
        td.subTableHeader
        {
          text-align: center;
          padding-bottom: 6px;
          font-family: sans-serif;
          font-weight: bold;
          vertical-align: center;
        }

        /* All views: header item format */
        td.headerItem
        {
          text-align: right;
          padding-right: 6px;
          font-family: sans-serif;
          font-weight: bold;
          vertical-align: top;
          white-space: nowrap;
        }

        /* All views: header item value format */
        td.headerValue
        {
          text-align: left;
          color: #COLOR_15;
          font-family: sans-serif;
          font-weight: bold;
          white-space: nowrap;
        }

        /* All views: header item coverage table heading */
        td.headerCovTableHead
        {
          text-align: center;
          padding-right: 6px;
          padding-left: 6px;
          padding-bottom: 0px;
          font-family: sans-serif;
          font-size: 80%;
          white-space: nowrap;
        }

        /* All views: header item coverage table entry */
        td.headerCovTableEntry
        {
          text-align: right;
          color: #COLOR_15;
          font-family: sans-serif;
          font-weight: bold;
          white-space: nowrap;
          padding-left: 12px;
          padding-right: 4px;
          background-color: #COLOR_08;
        }

        /* All views: header item coverage table entry for high coverage rate */
        td.headerCovTableEntryHi
        {
          text-align: right;
          color: #COLOR_00;
          font-family: sans-serif;
          font-weight: bold;
          white-space: nowrap;
          padding-left: 12px;
          padding-right: 4px;
          background-color: #COLOR_04;
        }

        /* All views: header item coverage table entry for medium coverage rate */
        td.headerCovTableEntryMed
        {
          text-align: right;
          color: #COLOR_00;
          font-family: sans-serif;
          font-weight: bold;
          white-space: nowrap;
          padding-left: 12px;
          padding-right: 4px;
          background-color: #COLOR_13;
        }

        /* All views: header item coverage table entry for ow coverage rate */
        td.headerCovTableEntryLo
        {
          text-align: right;
          color: #COLOR_00;
          font-family: sans-serif;
          font-weight: bold;
          white-space: nowrap;
          padding-left: 12px;
          padding-right: 4px;
          background-color: #COLOR_10;
        }

        /* All views: header legend value for legend entry */
        td.headerValueLeg
        {
          text-align: left;
          color: #COLOR_00;
          font-family: sans-serif;
          font-size: 80%;
          white-space: nowrap;
          padding-top: 4px;
        }

        /* All views: color of horizontal ruler */
        td.ruler
        {
          background-color: #COLOR_03;
        }

        /* All views: version string format */
        td.versionInfo
        {
          text-align: center;
          padding-top: 2px;
          font-family: sans-serif;
          font-style: italic;
        }

        /* Directory view/File view (all)/Test case descriptions:
           table headline format */
        td.tableHead
        {
          text-align: center;
          color: #COLOR_14;
          background-color: #COLOR_03;
          font-family: sans-serif;
          font-size: 120%;
          font-weight: bold;
          white-space: nowrap;
          padding-left: 4px;
          padding-right: 4px;
        }

        span.tableHeadSort
        {
          padding-right: 4px;
        }

        /* Directory view/File view (all): filename entry format */
        td.coverFile
        {
          text-align: left;
          padding-left: 10px;
          padding-right: 20px;
          color: #COLOR_15;
          background-color: #COLOR_08;
          font-family: monospace;
        }

        /* Directory view/File view (all): filename entry format */
        td.overallOwner
        {
          text-align: center;
          font-style: bold;
          font-family: sans-serif;
          background-color: #COLOR_08;
          padding-right: 10px;
          padding-left: 10px;
        }

        /* Directory view/File view (all): filename entry format */
        td.ownerName
        {
          text-align: right;
          font-style: italic;
          font-family: sans-serif;
          background-color: $ownerBackground;
          padding-right: 10px;
          padding-left: 20px;
        }

        /* Directory view/File view (all): bar-graph entry format*/
        td.coverBar
        {
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_08;
        }

        /* Directory view/File view (all): bar-graph entry format*/
        td.owner_coverBar
        {
          padding-left: 10px;
          padding-right: 10px;
          background-color: $ownerBackground;
        }

        /* Directory view/File view (all): bar-graph outline color */
        td.coverBarOutline
        {
          background-color: #COLOR_00;
        }

        /* Directory view/File view (all): percentage entry for files with
           high coverage rate */
        td.coverPerHi
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_04;
          font-weight: bold;
          font-family: sans-serif;
        }

        /* 'owner' entry:  slightly lighter color than 'coverPerHi' */
        td.owner_coverPerHi
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: $ownerCovHi;
          font-weight: bold;
          font-family: sans-serif;
        }

        /* Directory view/File view (all): line count entry */
        td.coverNumDflt
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_08;
          white-space: nowrap;
          font-family: sans-serif;
        }

        /* td background color and font for the 'owner' section of the table */
        td.ownerTla
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: $ownerBackground;
          white-space: nowrap;
          font-family: sans-serif;
          font-style: italic;
        }

        /* Directory view/File view (all): line count entry for files with
           high coverage rate */
        td.coverNumHi
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_04;
          white-space: nowrap;
          font-family: sans-serif;
        }

        td.owner_coverNumHi
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: $ownerCovHi;
          white-space: nowrap;
          font-family: sans-serif;
        }

        /* Directory view/File view (all): percentage entry for files with
           medium coverage rate */
        td.coverPerMed
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_13;
          font-weight: bold;
          font-family: sans-serif;
        }

        td.owner_coverPerMed
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: $ownerCovMed;
          font-weight: bold;
          font-family: sans-serif;
        }

        /* Directory view/File view (all): line count entry for files with
           medium coverage rate */
        td.coverNumMed
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_13;
          white-space: nowrap;
          font-family: sans-serif;
        }

        td.owner_coverNumMed
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: $ownerCovMed;
          white-space: nowrap;
          font-family: sans-serif;
        }

        /* Directory view/File view (all): percentage entry for files with
           low coverage rate */
        td.coverPerLo
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_10;
          font-weight: bold;
          font-family: sans-serif;
        }

        td.owner_coverPerLo
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: $ownerCovLo;
          font-weight: bold;
          font-family: sans-serif;
        }

        /* Directory view/File view (all): line count entry for files with
           low coverage rate */
        td.coverNumLo
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_10;
          white-space: nowrap;
          font-family: sans-serif;
        }

        td.owner_coverNumLo
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: $ownerCovLo;
          white-space: nowrap;
          font-family: sans-serif;
        }

        /* File view (all): "show/hide details" link format */
        a.detail:link
        {
          color: #COLOR_06;
          font-size:80%;
        }

        /* File view (all): "show/hide details" link - visited format */
        a.detail:visited
        {
          color: #COLOR_06;
          font-size:80%;
        }

        /* File view (all): "show/hide details" link - activated format */
        a.detail:active
        {
          color: #COLOR_14;
          font-size:80%;
        }

        /* File view (detail): test name entry */
        td.testName
        {
          text-align: right;
          padding-right: 10px;
          background-color: #COLOR_08;
          font-family: sans-serif;
        }

        /* File view (detail): test percentage entry */
        td.testPer
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_08;
          font-family: sans-serif;
        }

        /* File view (detail): test lines count entry */
        td.testNum
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_08;
          font-family: sans-serif;
        }

        /* Test case descriptions: test name format*/
        dt
        {
          font-family: sans-serif;
          font-weight: bold;
        }

        /* Test case descriptions: description table body */
        td.testDescription
        {
          padding-top: 10px;
          padding-left: 30px;
          padding-bottom: 10px;
          padding-right: 30px;
          background-color: #COLOR_08;
        }

        /* Source code view: function entry */
        td.coverFn
        {
          text-align: left;
          padding-left: 10px;
          padding-right: 20px;
          color: #COLOR_15;
          background-color: #COLOR_08;
          font-family: monospace;
        }

        /* Source code view: function entry zero count*/
        td.coverFnLo
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_10;
          font-weight: bold;
          font-family: sans-serif;
        }

        /* Source code view: function entry nonzero count*/
        td.coverFnHi
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_08;
          font-weight: bold;
          font-family: sans-serif;
        }

        td.coverFnAlias
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 20px;
          color: #COLOR_15;
          /* make this a slightly different color than the leader - otherwise,
             otherwise the alias is hard to distinguish in the table */
          background-color: "#COLOR_17"; # very light pale grey/blue
          font-family: monospace;
        }

        /* Source code view: function entry zero count*/
        td.coverFnAliasLo
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: $ownerCovLo; # lighter red
          font-family: sans-serif;
        }

        /* Source code view: function entry nonzero count*/
        td.coverFnAliasHi
        {
          text-align: right;
          padding-left: 10px;
          padding-right: 10px;
          background-color: #COLOR_08;
          font-weight: bold;
          font-family: sans-serif;
        }

        /* Source code view: source code format */
        pre.source
        {
          font-family: monospace;
          white-space: pre;
          margin-top: 2px;
        }

        /* Source code view: line number format */
        span.lineNum
        {
          background-color: #COLOR_09;
        }

        /* Source code view: format for Cov legend */
        span.coverLegendCov
        {
          padding-left: 10px;
          padding-right: 10px;
          padding-bottom: 2px;
          background-color: #COLOR_07;
        }

        /* Source code view: format for NoCov legend */
        span.coverLegendNoCov
        {
          padding-left: 10px;
          padding-right: 10px;
          padding-bottom: 2px;
          background-color: #COLOR_12;
        }

        /* Source code view: format for the source code heading line */
        pre.sourceHeading
        {
          white-space: pre;
          font-family: monospace;
          font-weight: bold;
          margin: 0px;
        }

        /* All views: header legend value for low rate */
        td.headerValueLegL
        {
          font-family: sans-serif;
          text-align: center;
          white-space: nowrap;
          padding-left: 4px;
          padding-right: 2px;
          background-color: #COLOR_10;
          font-size: 80%;
        }

        /* All views: header legend value for med rate */
        td.headerValueLegM
        {
          font-family: sans-serif;
          text-align: center;
          white-space: nowrap;
          padding-left: 2px;
          padding-right: 2px;
          background-color: #COLOR_13;
          font-size: 80%;
        }

        /* All views: header legend value for hi rate */
        td.headerValueLegH
        {
          font-family: sans-serif;
          text-align: center;
          white-space: nowrap;
          padding-left: 2px;
          padding-right: 4px;
          background-color: #COLOR_04;
          font-size: 80%;
        }

        /* All views except source code view: legend format for low coverage */
        span.coverLegendCovLo
        {
          padding-left: 10px;
          padding-right: 10px;
          padding-top: 2px;
          background-color: #COLOR_10;
        }

        /* All views except source code view: legend format for med coverage */
        span.coverLegendCovMed
        {
          padding-left: 10px;
          padding-right: 10px;
          padding-top: 2px;
          background-color: #COLOR_13;
        }

        /* All views except source code view: legend format for hi coverage */
        span.coverLegendCovHi
        {
          padding-left: 10px;
          padding-right: 10px;
          padding-top: 2px;
          background-color: #COLOR_04;
        }

END_OF_CSS
        ;

    foreach my $tla (@SummaryInfo::tlaPriorityOrder) {
        my $title = $SummaryInfo::tlaToTitle{$tla};
        my $color = $lcovutil::tlaColor{$tla};
        foreach my $elem ("td", "span") {
            my $align = $elem eq 'td' ? "right" : "left";
            $css_data .= ($_ = <<"END_OF_SPAN")

        /* Source code view/table entry backround: format for lines classified as "$title" */
        $elem.tla$tla
        {
          text-align: $align;
          background-color: $color
        }
END_OF_SPAN
                ;
        }
    }

    # 'span' tags for date bins...
    #   probably should have one for each bin...
    $css_data .= ($_ = <<"END_OF_DATE_SPAN")

        /* Source code view: format for date/owner bin that is not hit */
        span.missBins
        {
          background-color: #COLOR_10 /* red */
        }
END_OF_DATE_SPAN
        ;

    # *************************************************************

    # Remove leading tab from all lines
    $css_data =~ s/^\t//gm;
    $css_data =~ s/^        //gm;    # and 8 spaces...

    my %palette = $dark_mode ?
        ('COLOR_00' => "e4e4e4",
         'COLOR_01' => "58a6ff",
         'COLOR_02' => "8b949e",
         'COLOR_03' => "3b4c71",
         'COLOR_04' => "006600",
         'COLOR_05' => "4b6648",
         'COLOR_06' => "495366",
         'COLOR_07' => "143e4f",
         'COLOR_08' => "1c1e23",
         'COLOR_09' => "202020",
         'COLOR_10' => "801b18",
         'COLOR_11' => "66001a",
         'COLOR_12' => "772d16",
         'COLOR_13' => "796a25",
         'COLOR_14' => "000000",
         'COLOR_15' => "58a6ff",
         'COLOR_16' => "eeeeee",
         'COLOR_17' => "E5DBDB",    # colors below not differentiated, yet
         'COLOR_18' => "82E0AA",
         'COLOR_19' => 'F9E79F',
         'COLOR_20' => 'EC7063',) :
        ('COLOR_00' => "000000",
         'COLOR_01' => "00cb40",
         'COLOR_02' => "284fa8",
         'COLOR_03' => "6688d4",
         'COLOR_04' => "a7fc9d",
         'COLOR_05' => "b5f7af",
         'COLOR_06' => "b8d0ff",
         'COLOR_07' => "cad7fe",
         'COLOR_08' => "dae7fe",
         'COLOR_09' => "efe383",
         'COLOR_10' => "ff0000",
         'COLOR_11' => "ff0040",
         'COLOR_12' => "ff6230",
         'COLOR_13' => "ffea20",
         'COLOR_14' => "ffffff",
         'COLOR_15' => "284fa8",
         'COLOR_16' => "ffffff",
         'COLOR_17' => "E5DBDB",    # very light pale grey/blue
         'COLOR_18' => "82E0AA",    # light green
         'COLOR_19' => 'F9E79F',    # light yellow
         'COLOR_20' => 'EC7063',    # lighter red
        );

    # Apply palette
    for (keys %palette) {
        $css_data =~ s/$_/$palette{$_}/gm;
    }

    print(CSS_HANDLE $css_data);

    close(CSS_HANDLE);
}

#
# get_bar_graph_code(base_dir, cover_found, cover_hit)
#
# Return a string containing HTML code which implements a bar graph display
# for a coverage rate of cover_hit * 100 / cover_found.
#

sub get_bar_graph_code($$$)
{
    my ($base_dir, $found, $hit) = @_;
    my $graph_code;

    # Check number of instrumented lines
    if ($found == 0) { return ""; }

    my $alt       = rate($hit, $found, "%");
    my $width     = rate($hit, $found, undef, 0);
    my $remainder = 100 - $width;

    # Decide which .png file to use
    my $png_name =
        $rate_png[classify_rate($found, $hit, $med_limit, $hi_limit)];

    if ($width == 0) {
        # Zero coverage
        $graph_code = (<<END_OF_HTML);
                <table border=0 cellspacing=0 cellpadding=1><tr><td class="coverBarOutline"><img src="${base_dir}snow.png" width=100 height=10 alt="$alt"></td></tr></table>
END_OF_HTML
    } elsif ($width == 100) {
        # Full coverage
        $graph_code = (<<END_OF_HTML);
                <table border=0 cellspacing=0 cellpadding=1><tr><td class="coverBarOutline"><img src="${base_dir}$png_name" width=100 height=10 alt="$alt"></td></tr></table>
END_OF_HTML
    } else {
        # Positive coverage
        $graph_code = (<<END_OF_HTML);
                <table border=0 cellspacing=0 cellpadding=1><tr><td class="coverBarOutline"><img src="${base_dir}$png_name" width=$width height=10 alt="$alt"><img src="${base_dir}snow.png" width=$remainder height=10 alt="$alt"></td></tr></table>
END_OF_HTML
    }

    # Remove leading tabs from all lines
    $graph_code =~ s/^\t+//gm;
    chomp($graph_code);

    return ($graph_code);
}

#
# sub classify_rate(found, hit, med_limit, high_limit)
#
# Return 0 for low rate, 1 for medium rate and 2 for hi rate.
#

sub classify_rate($$$$)
{
    my ($found, $hit, $med, $hi) = @_;

    if ($found == 0) {
        return 2;
    }
    my $rate = rate($hit, $found);
    if ($rate < $med) {
        return 0;
    } elsif ($rate < $hi) {
        return 1;
    }
    return 2;
}

#
# write_html(filehandle, html_code)
#
# Write out HTML_CODE to FILEHANDLE while removing a leading tabulator mark
# in each line of HTML_CODE.
#

sub write_html(*$)
{
    local *HTML_HANDLE = $_[0];
    my $html_code = $_[1];

    # Remove leading tab from all lines
    $html_code =~ s/^\t//gm;

    print(HTML_HANDLE $html_code) or
        die("ERROR: cannot write HTML data ($!)\n");
}

#
# write_html_prolog(filehandle, base_dir, pagetitle)
#
# Write an HTML prolog common to all HTML files to FILEHANDLE. PAGETITLE will
# be used as HTML page title. BASE_DIR contains a relative path which points
# to the base directory.
#

sub write_html_prolog(*$$)
{
    my $basedir   = $_[1];
    my $pagetitle = $_[2];
    my $prolog;

    $prolog = $html_prolog;
    $prolog =~ s/\@pagetitle\@/$pagetitle/g;
    $prolog =~ s/\@basedir\@/$basedir/g;

    write_html($_[0], $prolog);
}

#
# write_header_prolog(filehandle, base_dir)
#
# Write beginning of page header HTML code.
#

sub write_header_prolog(*$)
{
    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
          <table width="100%" border=0 cellspacing=0 cellpadding=0>
            <tr><td class="title">$title</td></tr>
            <tr><td class="ruler"><img src="$_[1]glass.png" width=3 height=3 alt=""></td></tr>

            <tr>
              <td width="100%">
                <table cellpadding=1 border=0 width="100%">
END_OF_HTML

    # *************************************************************
}

#
# write_header_line(handle, content)
#
# Write a header line with the specified table contents.
#

sub write_header_line(*@)
{
    my ($handle, @content) = @_;

    write_html($handle, "          <tr>\n");
    foreach my $entry (@content) {
        my ($width, $class, $text, $colspan, $title) = @{$entry};
        my %tags = ("width"   => $width,
                    "class"   => $class,
                    "colspan" => $colspan,
                    "title"   => $title);
        my $str = "            <td";
        while (my ($t, $v) = each(%tags)) {
            $str .= " $t=\"$v\""
                if defined($v);
        }
        $str .= '>';
        $str .= $text
            if defined($text);
        $str .= "</td>\n";
        # so 'str' looke like '<td width="value" colspan="value">whatever</td>'
        write_html($handle, $str);
    }
    write_html($handle, "          </tr>\n");    # then end the row
}

#
# write_header_epilog(filehandle, base_dir)
#
# Write end of page header HTML code.
#

sub write_header_epilog(*$)
{
    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
                  <tr><td><img src="$_[1]glass.png" width=3 height=3 alt=""></td></tr>
                </table>
              </td>
            </tr>

            <tr><td class="ruler"><img src="$_[1]glass.png" width=3 height=3 alt=""></td></tr>
          </table>

END_OF_HTML
    # *************************************************************
}

#
# write_file_table_prolog(handle, file_heading, binHeading, primary_key, ([heading, num_cols], ...))
#
# Write heading for file table.
#

sub write_file_table_prolog(*$$$@)
{
    my ($handle, $file_heading, $bin_heading, $primary_key, @columns) = @_;
    my $num_columns = 0;
    my $file_width;
    my $col;
    my $width;

    $width = 20 if (scalar(@columns) == 1);
    $width = 10 if (scalar(@columns) == 2);
    $width = 8 if (scalar(@columns) > 2);

    foreach $col (@columns) {
        my ($heading, $cols, $titles) = @{$col};
        if ($titles) {
            $num_columns += scalar(@$titles);
        } else {
            $num_columns += $cols;
        }
    }
    $file_width = 100 - $num_columns * $width;

    # Table definition
    write_html($handle, <<END_OF_HTML);
          <center>
          <table width="80%" cellpadding=1 cellspacing=1 border=0>

            <tr>
              <td width="$file_width%"><br></td>
END_OF_HTML
    if (defined($bin_heading)) {
        # owner or date column
        write_html($handle, <<END_OF_HTML);
              <td width=15</td>
END_OF_HTML
    }
    # Empty first row
    foreach $col (@columns) {
        my ($heading, $cols) = @{$col};

        while ($cols-- > 0) {
            write_html($handle, <<END_OF_HTML);
            <td width="$width%"></td>
END_OF_HTML
        }
    }
    # Next row
    if ($primary_key eq "name") {
        my $spanType = defined($bin_heading) ? "colspan" : "rowspan";
        write_html($handle, <<END_OF_HTML);
            </tr>

            <tr>
              <td class="tableHead" $spanType=2>$file_heading</td>
END_OF_HTML
    } else {
        my $t = ucfirst($primary_key);
        # a bit of a hack...just subtitute the primary key and related
        #   strings into the 'file heading' link - so we display the
        #   'sort' widget
        if ($primary_key eq 'owner' &&
            $file_heading =~ /^([^ ]+) <span/) {
            my $viewType = $1;
            $file_heading =~ s/$viewType/$t/;
            $file_heading =~ s/file name/$primary_key/g;
            $t            = $file_heading;
            $file_heading = $viewType;
        }
        write_html($handle, <<END_OF_HTML);
            </tr>

            <tr>
              <td class="tableHead" rowspan=2>$t</td>
              <td class="tableHead" rowspan=2>$file_heading</td>
END_OF_HTML
    }
    # Heading row
    foreach $col (@columns) {
        my ($heading, $cols, $titles) = @{$col};
        my $colspan = "";
        my $rowspan = "";
        $colspan = " colspan=$cols" if ($cols > 1);
        $rowspan = " rowspan=2" if (!defined($titles));
        write_html($handle, <<END_OF_HTML);
        <td class="tableHead"$colspan$rowspan>$heading</td>
END_OF_HTML
    }
    write_html($handle, <<END_OF_HTML);
            </tr>
            <tr>
END_OF_HTML

    # title row
    if (defined($bin_heading)) {
        # Next row
        my $str = ucfirst($bin_heading);
        write_html($handle, <<END_OF_HTML);
              <td class="tableHead">Name</td>
              <td class="tableHead">$str</td>
END_OF_HTML
    }

    foreach $col (@columns) {
        my ($heading, $cols, $titles) = @{$col};
        my $colspan = "";
        my $rowspan = "";

        if (defined($titles)) {
            foreach my $t (@$titles) {
                my $span  = "";
                my $popup = '';
                if ("ARRAY" eq ref($t)) {
                    my ($tla, $num, $help) = @$t;
                    $span  = " colspan=" . $num if $num > 1;
                    $popup = " title=\"$help\""
                        if (defined $help);
                    $t = $tla;
                }
                write_html($handle, <<END_OF_HTML);
                    <td class="tableHead"$span$popup> $t</td>
END_OF_HTML
            }
        }
    }
    write_html($handle, <<END_OF_HTML);
            </tr>
END_OF_HTML
}

# write_file_table_entry(handle, base_dir,
#                        [ name, [filename, fileDetails, fileHref],
#                          rowspan, primary_key, is_secondary, fileview,
#                          page_type, page_link, dirSummary, showDetailCol,
#                          asterisk ],
#                        ([ found, hit, med_limit, hi_limit, graph ], ..)
#
# Write an entry of the file table.
# $fileview:  0 == 'table is listing directories', 1 == 'list files'
#

sub write_file_table_entry(*$$@)
{
    my ($handle, $base_dir, $data, @entries) = @_;
    my ($name, $callbackData, $rowspan,
        $primary_key, $is_secondary, $fileview,
        $page_type, $page_link, $dirSummary,
        $showBinDetailColumn, $asterisk) = @$data;
    my $esc_name = escape_html($name);
    #$esc_name .= "<sup>" . escape_html($asterisk) . "</sup>"
    #  if defined($asterisk);
    my $namecode = $esc_name;
    my $owner;

    my ($filename, $fileDetails, $file_link, $cbData) = @$callbackData;
    # Add link to source if provided
    my $anchor = 'NAME';
    if (!$is_secondary &&
        defined($page_link) &&
        $page_link ne "") {
        $namecode = "<a href=\"$page_link\">$esc_name</a>";
        $owner    = "";
    } elsif ($is_secondary &&
             $primary_key ne 'name' &&
             defined($file_link) &&
             $file_link ne "") {
        $namecode = "<a href=\"$file_link\">" . $esc_name . "</a>";
    } elsif ($is_secondary &&
             $primary_key ne 'name' &&
             $name eq $filename) {
        # get here when we suppressed the sourceview - so the file link
        # is not defined
        $namecode = $esc_name;
    } elsif (defined($primary_key)) {
        $namecode = $esc_name;
        # we want the the HREF anchor on the column 1 entry -
        #   the column 0 entry may span many rows - so navigation to that
        #   entry (e.g., to find all the files in the "(7..30] days" bin)
        #   may be rendered such that the first element in the bin is not
        #   visible (you have to scroll up to see it).
        # the fix is to put the anchor in the next column
        if ($primary_key eq 'owner') {
            $anchor = "<a id=$name>NAME</a>";
        } elsif ($primary_key eq 'date') {
            my $bin = $SummaryInfo::ageHeaderToBin{$name};
            $anchor = "<a id=$bin>NAME</a>";
        }
    }

    my $tableHref;
    if (defined($file_link)) {
        if ($main::frames) {
            # href to anchor in frame doesn't seem to work in either firefox
            #   or chrome.  However, this seems like the right syntax.
            $tableHref .= "href=\"$file_link#__LINE__\" target=\"source\""
                if 0;
        } else {
            $tableHref = "href=\"$file_link#__LINE__\"";
        }
    }
    # First column: name
    my ($nameClass, $prefix);
    if ($is_secondary) {
        $nameClass = $primary_key ne 'name' ? "ownerName" : 'coverFile';
        $prefix    = "owner_";
    } else {
        $nameClass = 'coverFile';
        $prefix    = "";
    }
    if ($is_secondary &&
        (   $primary_key eq 'name' ||
            ($primary_key ne 'name' &&
                $fileview == 0))
    ) {
        # link to the entry in date/owner 'summary' table
        my $href = "<a href=\"";
        my $bin  = "";
        if ($fileview == 0 &&
            $primary_key ne 'name') {
            $href .= $filename . '/';
            $bin = $cbData if defined($cbData);
        }
        $href .= "index";

        my $help;
        if ($page_type eq 'owner') {
            $bin = $esc_name
                if ($primary_key eq 'name');
            $href .= "-bin_owner." . $html_ext . "#" . $bin;
            $help = "owner $bin";
        } elsif ($page_type eq 'date') {
            $bin = $SummaryInfo::ageHeaderToBin{$name}
                if ($primary_key eq 'name');

            $href .= "-bin_date." . $html_ext . "#$bin";
            $help = "the period '" . $SummaryInfo::ageGroupHeader[$bin] . "'";
        } else {
            die("unexpected type '$page_type'");
        }

        $href .= "\" title=\"go to coverage summary for $help\">$esc_name</a>";
        $namecode = $href;
    }
    my $span = (1 == $rowspan) ? "" : " rowspan=$rowspan";
    write_html($handle, <<END_OF_HTML);
            <tr>
              <td class="$nameClass"$span>$namecode</td>
END_OF_HTML

    # no 'owner' column if the entire directory is not part of the project
    #  (i.e., no files in this directory are in the repo)
    if ((defined($showBinDetailColumn) && $dirSummary->hasOwnerInfo()) ||
        (defined($primary_key)         &&
            $primary_key ne 'name' &&
            !$is_secondary)
    ) {
        $anchor =~ s/NAME/Total/;
        $anchor .= "<sup>" . escape_html($asterisk) . "</sup>"
            if defined($asterisk);
        write_html($handle, <<END_OF_HTML);
              <td class="overallOwner">$anchor</td>
END_OF_HTML
    }
    foreach my $entry (@entries) {
        my ($found, $hit, $med, $hi, $graph, $summary, $covType) = @{$entry};
        my $bar_graph;
        my $class;
        my $rate;

        # Generate bar graph if requested
        if ($graph) {
            if (!$is_secondary) {
                $class     = $prefix . 'coverBar';
                $bar_graph = get_bar_graph_code($base_dir, $found, $hit);
            } else {
                # graph is distracting for the second-level elements - skip them
                $bar_graph = "";
                $class     = 'coverFile';
            }
            write_html($handle, <<END_OF_HTML);
              <td class="$class" align="center">
                $bar_graph
              </td>
END_OF_HTML
        }
        # Get rate color and text
        if ($found == 0) {
            $rate  = "-";
            $class = "Hi";
        } else {
            $rate  = rate($hit, $found, "&nbsp;%");
            $class = $rate_name[classify_rate($found, $hit, $med, $hi)];
        }
        # Show negative number of items without coverage
        $hit -= $found    # negative number
            if ($main::opt_missed);

        write_html($handle, <<END_OF_HTML);
              <td class="${prefix}coverPer$class">$rate</td>
END_OF_HTML
        if ($summary) {
            my @keys = ("found");
            if ($main::show_hitTotalCol) {
                push(@keys, $opt_missed ? "missed" : "hit");
            }
            if ($main::show_tla) {
                push(@keys, @SummaryInfo::tlaPriorityOrder);
            }
            foreach my $key (@keys) {
                my $count = $summary->get($key);
                #print("$name: $key " . $summary->get($key));
                $class = $page_type ne "owner" ? "coverNumDflt" : "ownerTla";
                my $v = "";
                if (defined($count) && 0 != $count) {
                    $v = $key eq 'missed' ? -$count : $count;
                    # want to colorize the UNC, LBC, UIC rows if not zero
                    $class = "tla$key"
                        if (!$main::use_legacyLabels &&
                            grep(/^$key$/, ("UNC", "LBC", "UIC")));

                    # want to look in file details to build link to first
                    #   line...
                    if (!$main::no_sourceview &&
                        defined($tableHref)       &&
                        defined($fileDetails)     &&
                        'D' ne substr($key, 0, 1) &&
                        grep(/^$key$/, @SummaryInfo::tlaPriorityOrder)) {
                        my $line;
                        my $label =
                            $main::use_legacyLabels ?
                            $SummaryInfo::tlaToLegacySrcLabel{$key} :
                            $key;
                        my $title = "\"Go to first $label $covType ";
                        if ('fileOrDir' eq $page_type) {
                            # go to first line of the indicated type in the file
                            $line = $fileDetails->nextTlaGroup($key)
                                if $covType eq 'line';
                            $line = $fileDetails->nextBranchTlaGroup($key)
                                if $covType eq 'branch';
                        } elsif ('owner' eq $page_type) {
                            my $owner = $summary->owner();
                            $title .= "in '$owner' bin ";
                            $line = $fileDetails->nextInOwnerBin($owner, $key)
                                if $covType eq 'line';
                            $line =
                                $fileDetails->nextBranchInOwnerBin($owner, $key)
                                if $covType eq 'branch';
                        } elsif ('date' eq $page_type) {
                            my $agebin = $summary->bin();
                            $title .=
                                "in '$SummaryInfo::ageGroupHeader[$agebin]' bin ";
                            $line = $fileDetails->nextInDateBin($agebin, $key)
                                if $covType eq 'line';
                            $line =
                                $fileDetails->nextBranchInDateBin($agebin, $key)
                                if $covType eq 'branch';
                        } else {
                            die("unexpected page detail type '$page_type'");
                        }
                        $title .= "in $filename\"";
                        my $color =
                            $class eq "tla$key" ?
                            "style=\"background-color:$lcovutil::tlaColor{$key}\" "
                            :
                            "";
                        if (defined($line)) {
                            my $href = $tableHref;
                            $href =~ s/__LINE__/$line/;
                            $v = "<a $href ${color}title=$title>$v</a>";
                        }
                    }
                }
                write_html($handle, <<END_OF_HTML);
              <td class="$class">$v</td>
END_OF_HTML
            }

        } else {
            write_html($handle, <<END_OF_HTML);
              <td class="${prefix}coverNum$class">$hit / $found</td>
END_OF_HTML
        }
    }
    # End of row
    write_html($handle, <<END_OF_HTML);
            </tr>
END_OF_HTML
}

#
# write_file_table_detail_entry(filehandle, base_dir, test_name, bin_type, ([found, hit], ...))
#
# Write entry for detail section in file table.
#

sub write_file_table_detail_entry(*$$$@)
{
    my ($handle, $base_dir, $test, $showBinDetail, @entries) = @_;

    if ($test eq "") {
        $test = "<span style=\"font-style:italic\">&lt;unnamed&gt;</span>";
    } elsif ($test =~ /^(.*),diff$/) {
        $test = $1 . " (converted)";
    }
    # Testname
    write_html($handle, <<END_OF_HTML);
            <tr>
              <td class="testName" colspan=2>$test</td>
END_OF_HTML
    # Test data
    foreach my $entry (@entries) {
        my ($found, $hit, $covtype, $callback) = @{$entry};
        my $rate = rate($hit, $found, "&nbsp;%");
        if ('line' eq $covtype &&
            defined($showBinDetail)) {
            write_html($handle, "    <td class=\"testPer\"></td>\n");
        }
        write_html($handle, "    <td class=\"testPer\">$rate</td>\n");
        if ($covtype ne 'function') {
            write_html($handle,
                       "              <td class='testNum'>$found</td>\n");
            if ($main::show_hitTotalCol) {
                write_html($handle,
                           "              <td class='testNum'>$hit</td>\n");
            }
            if ($main::show_tla) {
                foreach my $tla (@SummaryInfo::tlaPriorityOrder) {
                    my $count = $callback->count($tla);
                    $count = "" if 0 == $count;
                    write_html($handle,
                               "    <td class=coverNumDflt>$count</td>\n");
                }
            }
        } else {
            write_html($handle,
                    "    <td class=\"testNum\">$found&nbsp;/&nbsp;$hit</td>\n");
        }
    }
    write_html($handle, "    </tr>\n");
}

#
# write_file_table_epilog(filehandle)
#
# Write end of file table HTML code.
#

sub write_file_table_epilog(*)
{
    # *************************************************************
    write_html($_[0], <<END_OF_HTML);
          </table>
          </center>
          <br>

END_OF_HTML
}

#
# write_test_table_prolog(filehandle, table_heading)
#
# Write heading for test case description table.
#

sub write_test_table_prolog(*$)
{
    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
          <center>
          <table width="80%" cellpadding=2 cellspacing=1 border=0>

            <tr>
              <td class="tableHead">$_[1]</td>
            </tr>

            <tr>
              <td class="testDescription">
                <dl>
END_OF_HTML

    # *************************************************************
}

#
# write_test_table_entry(filehandle, test_name, test_description)
#
# Write entry for the test table.
#

sub write_test_table_entry(*$$)
{
    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
          <dt>$_[1]<a id="$_[1]">&nbsp;</a></dt>
          <dd>$_[2]<br><br></dd>
END_OF_HTML

    # *************************************************************
}

#
# write_test_table_epilog(filehandle)
#
# Write end of test description table HTML code.
#

sub write_test_table_epilog(*)
{
    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
                </dl>
              </td>
            </tr>
          </table>
          </center>
          <br>

END_OF_HTML

    # *************************************************************
}

sub fmt_centered($$)
{
    my ($width, $text) = @_;
    my $w0 = length($text);
    my $w1 = $width > $w0 ? int(($width - $w0) / 2) : 0;
    my $w2 = $width > $w0 ? $width - $w0 - $w1 : 0;

    return (" " x $w1) . $text . (" " x $w2);
}

#
# write_source_prolog(filehandle)
#
# Write start of source code table.
#

sub write_source_prolog(**)
{
    my $lineno_heading     = " " x 9;
    my $branch_heading     = "";
    my $tlaWidth           = 4;
    my $fileHasProjectData = $_[1];
    my $age_heading        = "";
    my $owner_heading      = "";
    my $tla_heading        = "";
    if (defined($main::show_dateBins) &&
        $fileHasProjectData) {
        $age_heading   = fmt_centered(5, "Age");
        $owner_heading = fmt_centered(20, "Owner");
    }
    if (defined($main::show_tla)) {
        $tla_heading = fmt_centered($tlaWidth, "TLA");
    }
    my $line_heading   = fmt_centered($line_field_width, "Line data");
    my $source_heading = " Source code";

    if ($br_coverage) {
        $branch_heading = fmt_centered($br_field_width, "Branch data") . " ";
    }

    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
          <table cellpadding=0 cellspacing=0 border=0>
            <tr>
              <td><br></td>
            </tr>
            <tr>
              <td>
<pre class="sourceHeading">${age_heading} ${owner_heading} ${lineno_heading}${branch_heading}${tla_heading}${line_heading} ${source_heading}</pre>
<pre class="source">
END_OF_HTML

    # *************************************************************
}

sub cmp_blocks($$)
{
    my ($a, $b)   = @_;
    my ($fa, $fb) = ($a->[0], $b->[0]);

    return $fa->[0] <=> $fb->[0] if ($fa->[0] != $fb->[0]);
    return $fa->[1] <=> $fb->[1];
}

#
# get_branch_blocks(brdata)
#
# Group branches that belong to the same basic block.
#
# Returns: [block1, block2, ...]
# block:   [branch1, branch2, ...]
# branch:  [block_num, branch_num, taken_count, text_length, open, close]
#

sub get_branch_blocks($)
{
    my $brdata = shift;

    return () if (!defined($brdata));

    my $last_block_num;
    my $block = [];
    my @blocks;

    # Group branches
    foreach my $block_num (sort $brdata->blocks()) {
        my $blockData = $brdata->getBlock($block_num);
        my $branch    = 0;
        foreach my $br (@$blockData) {

            if (defined($last_block_num) && $block_num != $last_block_num) {
                push(@blocks, $block);
                $block = [];
            }
            my $br = [$block_num, $branch, $br, 3, 0, 0];
            push(@{$block}, $br);
            $last_block_num = $block_num;
            ++$branch;
        }
    }
    push(@blocks, $block) if (scalar(@{$block}) > 0);

    # Add braces to first and last branch in group
    foreach $block (@blocks) {
        $block->[0]->[$BR_OPEN] = 1;
        $block->[0]->[$BR_LEN]++;
        $block->[scalar(@{$block}) - 1]->[$BR_CLOSE] = 1;
        $block->[scalar(@{$block}) - 1]->[$BR_LEN]++;
    }

    return sort(cmp_blocks @blocks);
}

#
# get_block_len(block)
#
# Calculate total text length of all branches in a block of branches.
#

sub get_block_len($)
{
    my ($block) = @_;
    my $len = 0;

    foreach my $branch (@{$block}) {
        $len += $branch->[$BR_LEN];
    }

    return $len;
}

#
# get_branch_html(brdata, printCallbackStruct)
#
# Return a list of HTML lines which represent the specified branch coverage
# data in source code view.
#

sub get_branch_html($$)
{
    my ($brdata, $cbdata) = @_;
    my $differentialBranch;
    my $fileDetail = $cbdata->sourceDetail();
    if (defined($main::show_tla)) {
        my $lineNo   = $cbdata->lineNo();
        my $lineData = $cbdata->lineData()->line($lineNo);
        $differentialBranch = $lineData->differential_branch()
            if defined($lineData);
    }
    # build the 'blocks' array from differential data if we have it..
    my @blocks = get_branch_blocks(
                  defined($differentialBranch) ? $differentialBranch : $brdata);
    my $line_len = 0;
    my $line     = [];    # [branch2|" ", branch|" ", ...]
    my @lines;            # [line1, line2, ...]
    my @result;

    # Distribute blocks to lines
    foreach my $block (@blocks) {
        my $block_len = get_block_len($block);

        # Does this block fit into the current line?
        if ($line_len + $block_len <= $br_field_width) {
            # Add it
            $line_len += $block_len;
            push(@{$line}, @{$block});
            next;
        } elsif ($block_len <= $br_field_width) {
            # It would fit if the line was empty - add it to new
            # line
            push(@lines, $line);
            $line_len = $block_len;
            $line     = [@{$block}];
            next;
        }
        # Split the block into several lines
        foreach my $branch (@{$block}) {
            if ($line_len + $branch->[$BR_LEN] >= $br_field_width) {
                # Start a new line
                if (($line_len + 1 <= $br_field_width) &&
                    scalar(@{$line}) > 0 &&
                    !$line->[scalar(@$line) - 1]->[$BR_CLOSE]) {
                    # Try to align branch symbols to be in
                    # one # row
                    push(@{$line}, " ");
                }
                push(@lines, $line);
                $line_len = 0;
                $line     = [];
            }
            push(@{$line}, $branch);
            $line_len += $branch->[$BR_LEN];
        }
    }
    push(@lines, $line);

    my %tlaLinks;

    # Convert to HTML
    foreach $line (@lines) {
        my $current     = "";
        my $current_len = 0;

        foreach my $branch (@$line) {
            # Skip alignment space
            if ($branch eq " ") {
                $current .= " ";
                $current_len++;
                next;
            }

            my ($block_num, $br_num, $br, $len, $open, $close) = @{$branch};

            my $class;
            my $prefix;
            my $tla;
            if ('ARRAY' ne ref($br)) {
                # vanilla case - no differential coverage info
                die("differential branch coverage but no TLA")
                    if defined($differentialBranch);
                if ($br->data() eq '-') {
                    $class = "tlaUNC";
                } elsif ($br->data() == 0) {
                    $class = "tlaUNC";
                } else {
                    $class = 'tlaGBC';
                }
                $prefix = '';
            } else {
                die("differential branch coverage but no TLA")
                    unless defined($differentialBranch);
                $tla   = $br->[1];
                $br    = $br->[0];
                $class = "tla$tla";
                my $label =
                    $main::use_legacyLabels ?
                    $SummaryInfo::tlaToLegacySrcLabel{$tla} :
                    $tla;
                $prefix = $label . ": ";
            }
            my ($char, $title);

            my $br_name =
                defined($br->expr()) ? '"' . $br->expr() . '"' : $br_num;
            my $taken = $br->data();
            if ($taken eq '-') {
                $char  = "#";
                $title = "${prefix}Branch $br_name was not executed";
            } elsif ($taken == 0) {
                $char  = "-";
                $title = "${prefix}Branch $br_name was not taken";
            } else {
                $char  = "+";
                $title = "${prefix}Branch $br_name was taken $taken time" .
                    (($taken > 1) ? "s" : "");
            }
            $title = escape_html($title) if defined($br->expr());
            $current .= "[" if ($open);

            if (!$main::no_sourceview &&
                defined($differentialBranch)) {
                my $href;
                if (exists($tlaLinks{$tla})) {
                    $href = $tlaLinks{$tla};
                } else {
                    my $line = $differentialBranch->line();
                    my $next = $fileDetail->nextBranchTlaGroup($tla, $line);

                    $href = "<a href=\"#" . (defined($next) ? $next : 'top') .
                        "\" style=\"background-color:$lcovutil::tlaColor{$tla}\" title=\"TITLE\">$char</a>";
                    $tlaLinks{$tla} = $href;
                }
                $href =~ s#TITLE#$title#;
                my $space = "<span class=\"$class\"> </span>";
                $current .= $space . $href . $space;
            } else {
                $current .=
                    "<span class=\"$class\" title=\"$title\"> $char </span>";
            }
            $current .= "]" if ($close);
            $current_len += $len;
        }

        # Right-align result text
        if ($current_len < $br_field_width) {
            $current = (" " x ($br_field_width - $current_len)) . $current;
        }
        push(@result, $current);
    }

    return @result;
}

#
# format_count(count, width)
#
# Return a right-aligned representation of count that fits in width characters.
#

sub format_count($$)
{
    my ($count, $width) = @_;
    my $result;
    my $exp;

    $result = sprintf("%*.0f", $width, $count);
    while (length($result) > $width) {
        last if ($count < 10);
        $exp++;
        $count  = int($count / 10);
        $result = sprintf("%*s", $width, ">$count*10^$exp");
    }
    return $result;
}

#
# write_source_line(filehandle, cbdata, source, hit_count, brdata,
#                   printCallbackStruct)
#
# Write formatted source code line. Return a line in a format as needed
# by gen_png()
#

sub write_source_line(*$$$$)
{
    my ($handle, $srcline, $count, $brdata, $cbdata) = @_;
    my $line        = $cbdata->lineNo();
    my $fileCovInfo = $cbdata->lineData();
    my $source      = $srcline->text();
    my $src_owner   = $srcline->owner();
    $src_owner =~ s/@.*// if defined($src_owner);
    my $src_age = $srcline->age();
    my $source_format;
    my $count_format;
    my $result;
    my $anchor_start      = "";
    my $anchor_end        = "";
    my $count_field_width = $line_field_width - 1;
    my @br_html;
    my $html;
    my $tla;
    my $base_count;
    my $curr_count;
    my $bucket;

    my @prevData = ($cbdata->current('tla'),
                    $cbdata->current('owner'),
                    $cbdata->current('age'));

    # Get branch HTML data for this line
    @br_html = get_branch_html($brdata, $cbdata) if ($main::br_coverage);

    my $thisline = $fileCovInfo->lineMap()->{$line};
    my $tlaIsHref;
    if (!defined($thisline) ||
        (!defined($count) &&
            !($thisline->in_base() || $thisline->in_curr()))
    ) {
        $result        = "";
        $source_format = "";
        $count_format  = " " x $count_field_width;
        $tla           = $cbdata->tla(undef, $line);
    } else {
        $base_count = $thisline->base_count();
        $curr_count = $thisline->curr_count();
        $bucket     = $thisline->tla();
        # use callback data to keep track of the most recently seen TLA -
        #   $tla is either "   " (3 spaces) if same as previous or if no TLA
        #   we just stick "TLA " (4 characters) into the fixed-with source
        #   line - right before the count.
        $tla = $cbdata->tla($bucket, $line);
        if ($tla eq $bucket) {
            # maybe we want to link only the uncovered code categories?
            my $next = $cbdata->sourceDetail()->nextTlaGroup($bucket, $line);
            $tlaIsHref = 1;
            # if no next segment in this category - then go to top to page.
            $next = 'top' if (!defined($next));
            my $color = (
                  $tla ne 'UNK' ?
                      " style=\"background-color:$lcovutil::tlaColor{$bucket}\""
                  :
                      '');
            my $label =
                $main::use_legacyLabels ?
                $SummaryInfo::tlaToLegacySrcLabel{$tla} :
                $tla;
            my $popup = " title=\"Next $label group\"";
            $tla = "<a href=\"#$next\"$color$popup>$label</a>";
        }
        $source_format = "<span class=\"tla$bucket\">";

        my $pchar;
        if (exists($lcovutil::pngChar{$bucket})) {
            $pchar = $lcovutil::pngChar{$bucket};
        } else {
            lcovutil::ignorable_error($ERROR_UNKNOWN_CATEGORY,
                                      "unexpected TLA '$bucket'");
            $pchar = '';
            $count = 0 unless defined($count);
        }
        if ($bucket eq "ECB" ||
            $bucket eq "EUB") {
            !defined($count) or
                die("excluded code should have undefined count");
            # don't show count for excluded code
            $count_format = " " x $count_field_width;
            $result       = $pchar . $base_count;
        } else {
            if (!defined($count)) {
                # this is manufactured data...make something up
                $count = $curr_count;
            }
            defined($count) && "" ne $count or
                die("code should have defined count");
            $count_format = format_count($count, $count_field_width);
            $result       = $pchar . $count;
        }
        # '$result' is used to generate the PNG frame
        info(2,
             "    $bucket: line=$line " .
                 (defined($count) ? "count= $count " : "") .
                 "curr=$curr_count base=$base_count\n");
    }
    $result .= ":" . $source;

    # Write out a line number navigation anchor every $nav_resolution
    # lines if necessary
    $anchor_start = "<a id=\"$line\">";
    $anchor_end   = "</a>";

    # *************************************************************

    $html = $anchor_start;
    # we want to colorize the date/owner part of un-hit lines only
    my $html_continuation_leader = "";    # for continued lines
    if (defined($main::show_dateBins) &&
        $cbdata->sourceDetail()->isProjectFile()) {
        DATE_SECTION: {

            my $ageLen   = 5;
            my $ownerLen = 20;

            # need to space over on continuation lines
            $html_continuation_leader = ' ' x ($ageLen + $ownerLen + 2);

            if (!defined($count) &&
                (!defined($main::show_nonCodeOwners) ||
                    0 == $main::show_nonCodeOwners)
                &&
                (   !defined($bucket) ||
                    ($bucket ne 'EUB' &&
                        $bucket ne 'ECB'))
            ) {
                # suppress date- and owner entry on non-code lines
                $html .= $html_continuation_leader;
                last DATE_SECTION;
            }

            my $span    = "";
            my $endspan = "";
            my $bgcolor = "";
            if (defined($count) && 0 == $count) {
                # probably want to pick a color based on which
                #   date bin it is in.
                # right now, picking based on TLA.
                $bgcolor =
                    " style=\"background-color:$lcovutil::tlaColor{$bucket}\""
                    if (defined($bucket) &&
                        $bucket ne "EUB" &&
                        $bucket ne "ECB");

                #$html .= "<span class=\"missBins\">";
                if ("" ne $source_format) {
                    OWNER: {
                        if (!defined($src_owner) || !defined($src_age)) {
                            # maybe this should be a different error type?
                            main::ignorable_eror($ERROR_UNMAPPED_LINE,
                                      "undefined owner/age for $bucket $line " .
                                          $cbdata->sourceDetail()->path());
                            last OWNER;
                        }
                        # add a 'title="tooltip"' popup - to give owner, date, etc
                        my $title = "span title=\"$src_owner $src_age days ago";
                        if (defined($main::show_dateBins)) {
                            my $bin = SummaryInfo::findAgeBin($src_age);
                            $title .=
                                " (bin $bin: " .
                                $SummaryInfo::ageGroupHeader[$bin] . ")";
                        }
                        $title .= "\"";
                        $span = $source_format;
                        $span =~ s/span/$title/;
                        $endspan = "</span>";
                    }
                }
            }    # OWNER block

            # determine if this line is going to be the target of a 'date', 'owner'
            # or TLA navigation href.
            #  - is is possible for any of these to have changed from the previous
            #    line, even if the others are unchanged:
            #      - same TLA but different author
            #      - same author but different date bin, .. and so on
            # If it is a leader, then we need to insert the 'owner' and/or 'date'
            #   link to go to the next group in this bin - even if the owner or
            #   date bin has not changed from the previous line)
            my $tlaChanged = defined($bucket) && $prevData[0] ne $bucket;

            my $needOwnerHref = ($tlaChanged ||
                              (defined($bucket) && $prevData[1] ne $src_owner));

            my $newBin = SummaryInfo::findAgeBin($src_age);
            defined($prevData[2]) || $line == 1 or
                die("unexpected uninitialized age");

            my $needDateHref = (
                           $tlaChanged || (defined($bucket) &&
                               SummaryInfo::findAgeBin($prevData[2]) != $newBin)
            );

            if ($needDateHref) {
                my $matchLine = $cbdata->nextDate($newBin, $bucket);
                $needDateHref = 0
                    if (defined($matchLine) && $matchLine != $line);
            }
            if ($needOwnerHref) {
                # slightly complicated logic:
                #   - there can be non-code lines owned by someone else
                #     between code lines owned by '$src_owner', such that the
                #     all the code lines have the same TLA.
                # In that case, we just insert an href at the top of the
                # block to take us past all of of them - to the next code block
                # owned by $src_owner with this TLA, which separated by at least
                # one line of code either owned by someone else, or with a different
                # TLA.
                my $matchLine = $cbdata->nextOwner($src_owner, $bucket);
                # don't insert the owner href if this isn't the line we wanted
                $needOwnerHref = 0
                    if (defined($matchLine) && $matchLine != $line);
            }

            my $age   = $cbdata->age($src_age, $line);
            my $owner = $cbdata->owner($src_owner);

            # this HTML block turns into
            #   "<span ...>int name</span> " <- note trailing space
            #  .. but the age and name might be hrefs

            $html .= $span;
            # then 5 characters of 'age' (might be empty)
            if ($needDateHref) {
                # next line with this TLA, in this date bin
                my $next = $cbdata->sourceDetail()
                    ->nextInDateBin($newBin, $bucket, $line);
                $cbdata->nextDate($newBin, $bucket, $next);

                $next = "top" if (!defined($next));
                my $dateBin = $SummaryInfo::ageGroupHeader[$newBin];
                my $label =
                    $main::use_legacyLabels ?
                    $SummaryInfo::tlaToLegacySrcLabel{$bucket} :
                    $bucket;
                my $popup =
                    " title=\"next $label in &ldquo;$dateBin&rdquo; bin\"";
                $html .= ((' ' x ($ageLen - length($src_age))) .
                          "<a href=\"#$next\"$popup$bgcolor>$src_age</a> ");
            } else {
                $html .= sprintf("%${ageLen}s ", $age);
            }

            if ($needOwnerHref) {
                # next line with this TLA, by this owner..
                my $next = $cbdata->sourceDetail()
                    ->nextInOwnerBin($src_owner, $bucket, $line);
                $cbdata->nextOwner($src_owner, $bucket, $next);
                $next = "top" if (!defined($next));
                my $label =
                    $main::use_legacyLabels ?
                    $SummaryInfo::tlaToLegacySrcLabel{$bucket} :
                    $bucket;
                my $popup =
                    " title=\"next $label in &ldquo;$src_owner&rdquo; bin\"";
                # NOTE:  see note below about firefox nested span bug.
                #  this code just arranges to wrap an explicit 'span' around
                #  the space.
                my $space = ' ' x ($ownerLen - length($src_owner));
                my $href  = "<a href=\"#$next\"$popup$bgcolor>$src_owner</a>";
                if ('' ne $bgcolor &&
                    '' ne $space) {
                    $html .= "$endspan$href$span";
                } else {
                    $html .= $href;
                }
                $html .= $space;
            } else {
                $html .= sprintf("%-${ownerLen}s", $owner);
            }
            $html .= $endspan . ' ';    # add trailing space
        }
    }    # DATE_SECTION

    $html .= sprintf("<span class=\"lineNum\">%8d</span> ", $line);
    #printf("tla= " . $tla);
    #printf("html= " . $html);
    $html .= shift(@br_html) . ":" if ($main::br_coverage);

    $tla = ""
        if (!defined($main::show_tla));

    # 'source_format is the colorization, then the 3-letter TLA,
    #    then the hit count, then the source line
    if ($tlaIsHref) {
        # there seems to be a bug in firefox:
        #      <span class="foo"><a href...>link</a> whatever</span>
        #   renders as if the 'span' didn't exist (so the colorization of the
        #   link end - and the rest of the line doesn't pick up attributes
        #   from class 'foo'.
        # If I emit it as:
        #     <a href...>link</a><span ....> wheatever</span>
        #   (i.e., do not nest anchor inside the span) - then it works
        $html .= "$tla$source_format $count_format : ";
    } else {
        $html .= "$source_format$tla $count_format : ";
    }

    $html .= escape_html($source);
    $html .= "</span>" if ($source_format);
    $html .= $anchor_end . "\n";

    write_html($handle, $html);

    if ($main::br_coverage) {
        # Add lines for overlong branch information
        foreach (@br_html) {
            write_html($handle,
                       "$html_continuation_leader<span class=\"lineNum\">" .
                           ' ' x 8 . "</span> $_\n");
        }
    }
    # *************************************************************

    return ($result);
}

#
# write_source_epilog(filehandle)
#
# Write end of source code table.
#

sub write_source_epilog(*)
{
    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
        </pre>
              </td>
            </tr>
          </table>
          <br>

END_OF_HTML

    # *************************************************************
}

#
# write_html_epilog(filehandle, base_dir[, break_frames])
#
# Write HTML page footer to FILEHANDLE. BREAK_FRAMES should be set when
# this page is embedded in a frameset, clicking the URL link will then
# break this frameset.
#

sub write_html_epilog(*$;$)
{
    my $basedir    = $_[1];
    my $break_code = "";
    my $epilog;

    if (defined($_[2])) {
        $break_code = " target=\"_parent\"";
    }
    my $f =
        defined($main::footer) ? $footer :
        "Generated by: <a href=\"$lcov_url\"$break_code>$lcov_version</a>";

    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
          <table width="100%" border=0 cellspacing=0 cellpadding=0>
            <tr><td class="ruler"><img src="$_[1]glass.png" width=3 height=3 alt=""></td></tr>
            <tr><td class="versionInfo">$f</td></tr>
          </table>
          <br>
END_OF_HTML

    $epilog = $html_epilog;
    $epilog =~ s/\@basedir\@/$basedir/g;

    write_html($_[0], $epilog);
}

#
# write_frameset(filehandle, basedir, basename, pagetitle)
#
#

sub write_frameset(*$$$)
{
    my $frame_width = $overview_width + 40;

    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
        <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Frameset//EN">

        <html lang="en">

        <head>
          <meta http-equiv="Content-Type" content="text/html; charset=$charset">
          <title>$_[3]</title>
          <link rel="stylesheet" type="text/css" href="$_[1]gcov.css">
        </head>

        <frameset cols="$frame_width,*">
          <frame src="$_[2].gcov.overview.$html_ext" name="overview">
          <frame src="$_[2].gcov.$html_ext" name="source">
          <noframes>
            <center>Frames not supported by your browser!<br></center>
          </noframes>
        </frameset>

        </html>
END_OF_HTML

    # *************************************************************
}

#
# sub write_overview_line(filehandle, basename, line, link)
#
#

sub write_overview_line(*$$$)
{
    my $y1 = $_[2] - 1;
    my $y2 = $y1 + $nav_resolution - 1;
    my $x2 = $overview_width - 1;

    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
            <area shape="rect" coords="0,$y1,$x2,$y2" href="$_[1].gcov.$html_ext#$_[3]" target="source" alt="overview">
END_OF_HTML

    # *************************************************************
}

#
# write_overview(filehandle, basedir, basename, pagetitle, lines)
#
#

sub write_overview(*$$$$)
{
    my $index;
    my $max_line = $_[4] - 1;
    my $offset;

    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
        <!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">

        <html lang="en">

        <head>
          <title>$_[3]</title>
          <meta http-equiv="Content-Type" content="text/html; charset=$charset">
          <link rel="stylesheet" type="text/css" href="$_[1]gcov.css">
        </head>

        <body>
          <map name="overview">
END_OF_HTML

    # *************************************************************

    # Make $offset the next higher multiple of $nav_resolution
    $offset = ($nav_offset + $nav_resolution - 1) / $nav_resolution;
    $offset = sprintf("%d", $offset) * $nav_resolution;

    # Create image map for overview image
    for ($index = 1; $index <= $_[4]; $index += $nav_resolution) {
        # Enforce nav_offset
        if ($index < $offset + 1) {
            write_overview_line($_[0], $_[2], $index, 1);
        } else {
            write_overview_line($_[0], $_[2], $index, $index - $offset);
        }
    }

    # *************************************************************

    write_html($_[0], <<END_OF_HTML);
          </map>

          <center>
          <a href="$_[2].gcov.$html_ext#top" target="source">Top</a><br><br>
          <img src="$_[2].gcov.png" width=$overview_width height=$max_line alt="Overview" border=0 usemap="#overview">
          </center>
        </body>
        </html>
END_OF_HTML

    # *************************************************************
}

sub max($$)
{
    my ($a, $b) = @_;

    return $a if ($a > $b);
    return $b;
}

sub buildDateSummaryTable($$$$$$$$)
{
    my ($summary, $covType, $covCountCallback, $fileDetail,
        $nextLocationCallback, $title, $detailLink, $numRows)
        = @_;

    $title =
        "<a href=\"$detailLink\" title=\"Click to include date bin details in file table below\">$title</a>"
        if (defined($detailLink));

    my @table;

    my @dateSummary = [undef,               #width
                       "subTableHeader",    # class
                       $title,              # text
                       $numRows,            # colspan
    ];
    # only insert the label if there is data
    my $first = 1;
    my $page  = $detailLink;
    if (defined($page)) {
        $page =~ s/^index/index-bin_/;
        $page =~ s/^index-bin_-/index-bin_/;
    }

    for (my $bin = 0; $bin <= $#SummaryInfo::ageGroupHeader; ++$bin) {
        my $ageval = $summary->age_sample($bin);
        my $found  = &$covCountCallback($summary, "found", "age", $ageval);
        next
            if 0 == $found;
        my $hit = &$covCountCallback($summary, "hit", "age", $ageval);
        my $style =
            $rate_name[classify_rate($found, $hit, $med_limit, $hi_limit)];
        my $rate = rate($hit, $found, "&nbsp;%");
        my $href = $SummaryInfo::ageGroupHeader[$bin];
        if (defined($detailLink)) {
            $href =
                "<a href=\"$page#$bin\" title=\"click to go to coverage summary for the period '$href'\">$href</a>";
        }
        $hit -= $found    # negative number
            if ($main::opt_missed);
        my @dataRow = ([undef, "headerItem", $href . ":"],
                       [undef, "headerCovTableEntry$style", $rate],
                       [undef, "headerCovTableEntry", $found]);
        if ($main::show_hitTotalCol) {
            push(@dataRow, [undef, "headerCovTableEntry", $hit]);
        }
        if ($main::show_tla) {
            for my $tla (@SummaryInfo::tlaPriorityOrder) {
                my $value = &$covCountCallback($summary, $tla, "age", $ageval);
                my $class =
                    !$main::use_legacyLabels &&
                    0 != $value &&
                    grep(/^$tla$/, ("UNC", "LBC", "UIC")) ? "tla$tla" :
                    "headerCovTableEntry";
                # suppress zeros - make table less busy/easier to read
                if ("0" eq $value) {
                    $value = "";
                } elsif (!$main::no_sourceview &&
                         defined($fileDetail)           &&
                         defined($nextLocationCallback) &&
                         $tla ne 'DCB'                  &&
                         $tla ne 'DUB') {
                    # link to first entry
                    my $firstAppearance =
                        &$nextLocationCallback($fileDetail, $bin, $tla);
                    defined($firstAppearance) or
                        die(
                          "$tla: unexpected date bin $bin undef appearance for "
                              . $fileDetail->path());
                    my $dateBin = $SummaryInfo::ageGroupHeader[$bin];
                    my ($label, $color);
                    if ($main::use_legacyLabels) {
                        $label = $SummaryInfo::tlaToLegacy{$tla};
                        $color = "";
                    } else {
                        $label = $tla;
                        $color = " style=\"background-color:$class\"";
                    }
                    my $popup = " title=\"goto first $label ";
                    $popup .= $covType . ' '
                        if ($covType ne 'line');
                    $popup .= "in &ldquo;$dateBin&rdquo; bin\"";
                    $value =
                        "<a href=\"#$firstAppearance\"$popup$color>$value</a>";
                }
                push(@dataRow, [undef, $class, $value]);
            }
        }
        if ($first) {
            push(@table, \@dateSummary);
            $first = 0;
        }
        push(@table, \@dataRow);
    }
    return \@table;
}

sub buildOwnerSummaryTable($$$$$$$$)
{
    my ($ownerList, $summary, $covType, $fileDetail, $nextLocationCallback,
        $title, $detailLink, $numRows)
        = @_;

    $title .= " (containing " .
        ($main::show_ownerBins ? "" : "un-exercised ") . "code)";

    $title =
        "<a href=\"$detailLink\" title=\"Click to include ownership details in file table\">$title</a>"
        if (defined($detailLink));

    my $page = $detailLink;
    if (defined($page)) {
        $page =~ s/^index/index-bin_/;
        $page =~ s/^index-bin_-/index-bin_/;
    }

    my @table;
    my @ownerSummary = [undef,               #width
                        "subTableHeader",    # class
                        $title,              # text
                        $numRows,            # colspan
    ];

    my $first = 1;
    # owners are sorted from most uncovered lines to least
    foreach my $od (@$ownerList) {
        my ($name, $lineData, $branchData) = @$od;
        my $d = ($covType eq 'line') ? $lineData : $branchData;
        my ($missed, $found) = @$d;

        # only put user in table if they are responsible for at least one point
        next if $found == 0 or ($missed == 0 && $main::show_ownerBins ne 'all');

        if ($first) {
            $first = 0;
            push(@table, \@ownerSummary);
        }
        my $hit = $found - $missed;

        my $style =
            $rate_name[classify_rate($found, $hit, $med_limit, $hi_limit)];
        my $rate = rate($hit, $found, '&nbsp;%');

        my $href = $name;
        if (defined($detailLink)) {
            $href =
                "<a href=\"$page#$name\" title=\"click to go to coverage summary for owner '$name'\">$name</a>";
        }
        $hit -= $found    # negative number
            if ($main::opt_missed);
        my @dataRow = ([undef, "headerItem", $href . ":"],
                       [undef, "owner_coverPer$style", $rate],
                       [undef, "ownerTla", $found]);
        if ($main::show_hitTotalCol) {
            push(@dataRow, [undef, "ownerTla", $hit]);
        }
        if ($main::show_tla) {
            for my $tla (@SummaryInfo::tlaPriorityOrder) {
                my $value = $summary->owner_tlaCount($name, $tla, $covType);
                # suppress zeros - make table less busy/easier to read
                my $class =
                    !$main::use_legacyLabels &&
                    0 != $value &&
                    grep(/^$tla$/, ("UNC", "LBC", "UIC")) ? "tla$tla" :
                    "ownerTla";
                if ("0" eq $value) {
                    $value = "";
                } elsif (!$main::no_sourceview &&
                         defined($fileDetail) &&
                         defined($nextLocationCallback)) {
                    my $firstAppearance =
                        &$nextLocationCallback($fileDetail, $name, $tla);
                    defined($firstAppearance) or
                        die(
                          "$tla: unexpected owner $name undef appearance for " .
                              $fileDetail->path());
                    my ($label, $color);
                    if ($main::use_legacyLabels) {
                        $label = $SummaryInfo::tlaToLegacy{$tla};
                        $color = "";
                    } else {
                        $label = $tla;
                        $color = " style=\"background-color:$class\"";
                    }
                    my $popup = " title=\"goto first $label ";
                    $popup .= $covType . ' '
                        if ($covType ne 'line');
                    $popup .= "in &ldquo;$name&rdquo; bin\"";
                    $value =
                        "<a href=\"#$firstAppearance\"$popup$color>$value</a>";
                }
                push(@dataRow, [undef, $class, $value]);
            }
        }
        push(@table, \@dataRow);
    }
    return \@table;
}

sub buildHeaderSummaryTableRow
{
    my ($summary, $covType, $fileDetail, $nextLocationCallback) = @_;

    $fileDetail = undef
        if (!$main::show_tla &&
            (defined($fileDetail) && !$fileDetail->isProjectFile()));
    my @row;
    for my $tla (@SummaryInfo::tlaPriorityOrder) {
        my $value = $summary->get($tla, $covType);
        # suppress zeros - make table less busy/easier to read
        if ("0" eq $value) {
            $value = "";
        } elsif (!$main::no_sourceview &&
                 defined($fileDetail) &&
                 !($tla eq "DCB" || $tla eq "DUB")) {
            # deleted lines don't appear..
            my $firstAppearance = &$nextLocationCallback($fileDetail, $tla);
            defined($firstAppearance) or
                die(
                "$tla: unexpected undef appearance for " . $fileDetail->path());
            my $popup = " title=\"goto first ";
            $popup .= $covType . ' '
                if $covType ne 'line';
            my $label =
                $main::use_legacyLabels ? $SummaryInfo::tlaToLegacy{$tla} :
                $tla;
            $popup .= "$label\"";
            $value = "<a href=\"#$firstAppearance\"$popup>$value</a>";
        }
        push(@row, [undef, "headerCovTableEntry", $value]);
    }
    return @row;
}

# build an HTML string for the directory or file pathname, such
#  that each element is clickable - and takes you to the 'index' file
#  in the corresponding (transitive) parent directory
sub build_html_path($$$$$)
{
    my ($path, $key, $bin_type, $isFile, $isAbsolute) = @_;

    $path =~ s|^/||;
    my @path      = split('/', $path);
    my $html_path = "";
    if ($main::hierarchical &&
        scalar(@path) > 1) {
        pop(@path);    # remove 'self' - at the tail
        my $p   = "";
        my $sep = "";
        # need one fewer "../" entries for file pathname because the
        #  index file we are looking for is in the current directory (i.e.,
        #  not '../index.html'
        my $len = scalar(@path) - $isFile;
        foreach my $elem (@path) {
            my $base = "../" x $len;
            $elem       = '/' . $elem if $isAbsolute;
            $isAbsolute = 0;
            my $e = escape_html($elem);
            $html_path .=
                "$sep<a href=\"${base}index$key$bin_type.$html_ext\">$e</a>";
            $sep = '/';
            --$len;
        }
    }
    return $html_path;
}

#
# write_header(filehandle, ctrl, trunc_file_name, rel_file_name,
#              summaryInfo, optionalFileDetailInfo))
#  ctrl = (type, primary_key, sort_type, bin_type)
#
# Write a complete standard page header. TYPE may be (0, 1, 2, 3, 4)
# corresponding to (directory view header, file view header, source view
# header, test case description header, function view header)
#
# bin_type in (undef, "", "-owner", "-date")
#  - if 'bin' is set, then create link to 'vanilla' view of self, and
#    to corresponding view of parent
#      - i.e., from 'owner detail' directory page to "owner detail"
#        toplevel, and to my correspondign vanilla directory page.

sub write_header(*$$$$$)
{
    local *HTML_HANDLE = shift;
    my ($ctrl, $trunc_name, $rel_filename, $summary, $fileDetail) = @_;
    my ($type, $primary_key, $sort_type, $bin_type) = @$ctrl;
    my $base_dir;
    my $view;
    my @row_left;
    my @row_right;
    my $esc_trunc_name = escape_html($trunc_name);

    $bin_type = ""
        unless defined($bin_type);
    my $base_name     = File::Basename::basename($rel_filename);
    my $show_dateBins = $main::show_dateBins &&
        (!defined($fileDetail) || $fileDetail->isProjectFile());

    my $key = $primary_key ne "name" ? "-bin_$primary_key" : "";
    my $isAbsolutePath = (
                     $summary->is_directory(1) || ($summary->type() eq 'file' &&
                                            $summary->parent()->is_directory(1))
    );
    my $html_path =
        build_html_path($trunc_name, $key, $bin_type,
                        $summary->type() eq 'file',
                        $isAbsolutePath);

    # Prepare text for "current view" field
    if ($type == $HDR_DIR) {
        # Main overview
        $base_dir = "";
        if ($bin_type ne "" ||
            $primary_key ne 'name') {
            # this is the header of the 'top-level' page, for either 'owner'
            #   or 'date' binning - link back to vanilla top-level page
            $view =
                "<a href=\"index.$html_ext\" title=\"Click to return to 'flat' top-level page.\">$overview_title</a>";
        } else {
            $view = $overview_title;
        }
    } elsif ($type == $HDR_FILE) {
        # Directory overview
        $base_dir = get_relative_base_path($rel_filename);
        my $self_link;
        if ($main::hierarchical) {
            my $base = escape_html(File::Basename::basename($rel_filename));
            if ($base eq $rel_filename &&
                $isAbsolutePath) {
                $base = '/' . $base;
            }
            $self_link = $html_path;
            $self_link .= '/' if ('' ne $html_path);
            if ('name' ne $primary_key ||
                '' ne $bin_type) {
                $self_link .=
                    "<a href=\"index.$html_ext\" title=\"Click to return to 'flat' view of this directory.\">$base</a>";
            } else {
                $self_link .= $base;
            }
        } else {
            $esc_trunc_name = '/' . $esc_trunc_name
                if $isAbsolutePath;
            $self_link = $esc_trunc_name;
            if ('name' ne $primary_key ||
                '' ne $bin_type) {
                # go back to the 'vanilla' view of this directory
                $self_link =
                    "<a href=\"index.$html_ext\" title=\"Click to return to 'flat' view of this directory.\">$esc_trunc_name</a>";
            }
        }
        $view = "<a href=\"$base_dir" . "index$key$bin_type.$html_ext\">" .
            "$overview_title</a> - $self_link";
    } elsif ($type == $HDR_SOURCE || $type == $HDR_FUNC) {
        # File view
        my $dir_name = dirname($rel_filename);

        my $esc_base_name = escape_html($base_name);
        my $esc_dir_name  = escape_html($dir_name);
        $esc_dir_name = '/' . $esc_dir_name
            if $isAbsolutePath;

        $base_dir = get_relative_base_path($dir_name);
        # if using frames, to break frameset when clicking any of the links
        my $parent = $frames ? " target=\"_parent\"" : "";
        $view = "<a href=\"$base_dir" .
            "index.$html_ext\"$parent>" . "$overview_title</a> - ";
        if ($main::hierarchical) {
            $html_path =~ s/<a/<a$parent/g;
            $view .= $html_path;
        } else {
            $view .= "<a href=\"index.$html_ext\"$parent>$esc_dir_name</a>";
        }
        $view .= " - $esc_base_name";

        # Add function suffix
        if ($func_coverage) {
            $view .= "<span style=\"font-size: 80%;\">";
            if ($type == $HDR_SOURCE) {
                if ($sort) {
                    $view .=
                        " (source / <a href=\"$base_name.func-sort-c.$html_ext\">functions</a>)";
                } else {
                    $view .=
                        " (source / <a href=\"$base_name.func.$html_ext\">functions</a>)";
                }
            } elsif ($type == $HDR_FUNC) {
                $view .=
                    " (<a href=\"$base_name.gcov.$html_ext\">source</a> / functions)";
            }
            $view .= "</span>";
        }
    } elsif ($type == $HDR_TESTDESC) {
        # Test description header
        $base_dir = "";
        $view     = "<a href=\"$base_dir" . "index.$html_ext\">" .
            "$overview_title</a> - test case descriptions";
    }

    # Prepare text for "test" field
    my $test = escape_html($test_title);

    # Append link to test description page if available
    if (%test_description && ($type != $HDR_TESTDESC)) {
        if ($frames && ($type == $HDR_SOURCE || $type == $HDR_FUNC)) {
            # Need to break frameset when clicking this link
            $test .=
                " ( <span style=\"font-size:80%;\">" . "<a href=\"$base_dir" .
                "descriptions.$html_ext\" target=\"_parent\">" .
                "view descriptions</a></span> )";
        } else {
            $test .=
                " ( <span style=\"font-size:80%;\">" . "<a href=\"$base_dir" .
                "descriptions.$html_ext\">" . "view descriptions</a></span> )";
        }
    }

    # Write header
    write_header_prolog(*HTML_HANDLE, $base_dir);

    # Left row
    push(@row_left,
         [["10%", "headerItem", "Current view:"], ["10%", "headerValue", $view]
         ]);
    my $label = defined($baseline_title) ? "Current" : "Test";
    push(@row_left,
         [[undef, "headerItem", "$label:"], [undef, "headerValue", $test]]);
    push(@row_left,
         [[undef, "headerItem", "$label Date:"],
          [undef, "headerValue", $current_date]
         ]);
    if (defined($baseline_title)) {
        push(@row_left,
             [[undef, "headerItem", "Baseline:"],
              [undef, "headerValue", $baseline_title]
             ]);
        push(@row_left,
             [[undef, "headerItem", "Baseline Date:"],
              [undef, "headerValue", $baseline_date]
             ]);
    }
    if ($type != $HDR_SOURCE &&
        (defined($main::show_ownerBins) ||
            defined($SourceFile::annotateScript))
    ) {
        # we are going to have 3 versions of of the page:
        #   flat, with owner bin data, with date bin data
        # so label which one this is
        my $thisView;
        if ($bin_type eq '-owner') {
            $thisView = "Ownership bin detail";
        } elsif ($bin_type eq '-date') {
            $thisView = "Date bin detail";
        } else {
            $bin_type eq "" or
                die("unexpected bin detail type $bin_type");
            if ($primary_key eq 'name') {
                $thisView = "Flat";
            } elsif ($primary_key eq 'date') {
                $thisView = "Date bin summary";
            } else {
                die("inexpected key $primary_key")
                    unless ($primary_key eq 'owner');
                $thisView = "Owner bin summary";
            }
        }
        push(@row_left,
             [[undef, 'headerItem', 'View type:'],
              [undef, 'headerValue', $thisView]
             ]);
    }

    # Right row
    if ($legend && ($type == $HDR_SOURCE || $type == $HDR_FUNC)) {
        my $text = <<END_OF_HTML;
            Lines:
            <span class="coverLegendCov">hit</span>
            <span class="coverLegendNoCov">not hit</span>
END_OF_HTML
        if ($main::br_coverage) {
            $text .= <<END_OF_HTML;
            | Branches:
            <span class="coverLegendCov">+</span> taken
            <span class="coverLegendNoCov">-</span> not taken
            <span class="coverLegendNoCov">#</span> not executed
END_OF_HTML

        }
        push(@row_left,
             [[undef, "headerItem", "Legend:"],
              [undef, "headerValueLeg", $text]
             ]);
    } elsif ($legend && ($type != $HDR_TESTDESC)) {
        my $text = <<END_OF_HTML;
            Rating:
            <span class="coverLegendCovLo" title="Coverage rates below $med_limit % are classified as low">low: &lt; $med_limit %</span>
            <span class="coverLegendCovMed" title="Coverage rates between $med_limit % and $hi_limit % are classified as medium">medium: &gt;= $med_limit %</span>
            <span class="coverLegendCovHi" title="Coverage rates of $hi_limit % and more are classified as high">high: &gt;= $hi_limit %</span>
END_OF_HTML
        push(@row_left,
             [[undef, "headerItem", "Legend:"],
              [undef, "headerValueLeg", $text]
             ]);
    }
    if ($type == $HDR_TESTDESC) {
        push(@row_right, [["80%"]]);
    } else {
        my $totalTitle = "Covered + Uncovered code";
        my $hitTitle   = "Exercised code only";
        if (defined($main::base_filename)) {
            $totalTitle .= " (not including EUB, ECB, DUB, DCB categories)";
            $hitTitle   .= " (CBC + GBC + GNC + GIC)";
        }

        my @headerRow = (["5%", undef, undef],
                         ["5%", "headerCovTableHead", "Coverage"],
                         ["5%", "headerCovTableHead",
                          "Total", undef,
                          $totalTitle
                         ]);
        if ($main::show_hitTotalCol) {
            # legacy view, or we have all the differential categories
            #-  thus also want a summary
            $hitTitle = $main::use_legacyLabels ? undef : $hitTitle;
            push(@headerRow,
                 ["5%", "headerCovTableHead",
                  $main::opt_missed ? "Missed" : "Hit",
                  undef, $hitTitle
                 ]);
        }
        if ($main::show_tla) {
            for my $tla (@SummaryInfo::tlaPriorityOrder) {
                my ($title, $label);
                if ($main::use_legacyLabels) {
                    $label = $SummaryInfo::tlaToLegacy{$tla};
                } else {
                    $label = "<span class=\"tla$tla\">$tla</span>";
                    $title = $SummaryInfo::tlaToTitle{$tla};
                }
                push(@headerRow,
                     ["5%", "headerCovTableHead", $label, undef, $title]);
            }
        }
        push(@row_right, \@headerRow);
    }
    # Line coverage
    my $tot   = $summary->l_found();
    my $hit   = $summary->l_hit();
    my $style = $rate_name[classify_rate($tot, $hit, $med_limit, $hi_limit)];
    my $rate  = rate($hit, $tot, "&nbsp;%");
    $hit -= $tot
        if $main::opt_missed;    # negative number
    my @dataRow = ([undef, "headerItem", "Lines:"],
                   [undef, "headerCovTableEntry$style", $rate],
                   [undef, "headerCovTableEntry", $tot]);
    if ($main::show_hitTotalCol) {
        push(@dataRow, [undef, "headerCovTableEntry", $hit]);
    }
    if ($main::show_tla) {
        my @tlaRow =
            buildHeaderSummaryTableRow($summary, 'line', $fileDetail,
                                       \&SourceFile::nextTlaGroup);
        push(@dataRow, @tlaRow);
    }
    push(@row_right, \@dataRow)
        if ($type != $HDR_TESTDESC);
    # Function coverage
    if ($func_coverage) {
        my $tot = $summary->f_found();
        my $hit = $summary->f_hit();
        $style =
            $rate_name[classify_rate($tot, $hit, $fn_med_limit, $fn_hi_limit)];
        $rate = rate($hit, $tot, "&nbsp;%");
        $hit -= $tot
            if $main::opt_missed;    # negative number
        my @dataRow = ([undef, "headerItem", "Functions:"],
                       [undef, "headerCovTableEntry$style", $rate],
                       [undef, "headerCovTableEntry", $tot]);
        if ($main::show_hitTotalCol) {
            push(@dataRow, [undef, "headerCovTableEntry", $hit]);
        }
        if ($main::show_tla) {
            # no file position for function (yet)
            my @tlaRow =
                buildHeaderSummaryTableRow($summary, 'function', undef, undef);
            push(@dataRow, @tlaRow);
        }
        push(@row_right, \@dataRow)
            if ($type != $HDR_TESTDESC);
    }
    # Branch coverage
    if ($br_coverage) {
        my $tot = $summary->b_found();
        my $hit = $summary->b_hit();
        $style =
            $rate_name[classify_rate($tot, $hit, $br_med_limit, $br_hi_limit)];
        $rate = rate($hit, $tot, "&nbsp;%");
        $hit -= $tot
            if $main::opt_missed;    # negative number
        my @dataRow = ([undef, "headerItem", "Branches:"],
                       [undef, "headerCovTableEntry$style", $rate],
                       [undef, "headerCovTableEntry", $tot]);
        if ($main::show_hitTotalCol) {
            push(@dataRow, [undef, "headerCovTableEntry", $hit]);
        }
        if ($main::show_tla) {
            my @tlaRow =
                buildHeaderSummaryTableRow($summary, 'branch', $fileDetail,
                                           \&SourceFile::nextBranchTlaGroup);
            push(@dataRow, @tlaRow);
        }
        push(@row_right, \@dataRow)
            if ($type != $HDR_TESTDESC);
    }

    # Aged coverage
    if ($show_dateBins) {
        # make a space in the table between before date bins
        my $dateBinDetailPage = "index-date.$html_ext"
            if $type != $HDR_SOURCE;

        my $table =
            buildDateSummaryTable(
                        $summary, "line",
                        \&SummaryInfo::lineCovCount, $fileDetail,
                        \&SourceFile::nextInDateBin, "Line coverage date bins:",
                        $dateBinDetailPage, scalar(@dataRow));
        push(@row_right, @$table);

        if ($func_coverage) {
            my $fn_table =
                buildDateSummaryTable($summary,
                                      "function",
                                      \&SummaryInfo::functionCovCount,
                                      $fileDetail,
                                      undef,
                                      "Function coverage date bins:",
                                      $dateBinDetailPage,
                                      scalar(@dataRow));
            push(@row_right, @$fn_table);
        }

        if ($br_coverage) {
            my $br_table =
                buildDateSummaryTable($summary,
                                      "branch",
                                      \&SummaryInfo::branchCovCount,
                                      $fileDetail,
                                      \&SourceFile::nextBranchInDateBin,
                                      "Branch coverage date bins:",
                                      $dateBinDetailPage,
                                      scalar(@dataRow));
            push(@row_right, @$br_table);
        }
    }
    # owner bins..
    if (defined($main::show_ownerBins)) {
        # first, make sure there is owner data here (ie., owner data
        #   was collected, or both that there is owner data and some
        #   owners have uncovered code)
        my $ownerList = $summary->findOwnerList($main::show_ownerBins &&
                                                $main::show_ownerBins eq 'all');
        if (defined($ownerList)) {
            my $ownerBinDetailPage = "index-owner.$html_ext"
                if $type != $HDR_SOURCE;

            my $table =
                buildOwnerSummaryTable($ownerList,
                                       $summary,
                                       'line',
                                       $fileDetail,
                                       \&SourceFile::nextInOwnerBin,
                                       "Line coverage ownership bins",
                                       $ownerBinDetailPage,
                                       scalar(@dataRow));
            push(@row_right, @$table);

            if ($br_coverage) {
                my $br_table =
                    buildOwnerSummaryTable($ownerList,
                                           $summary,
                                           'branch',
                                           $fileDetail,
                                           \&SourceFile::nextBranchInOwnerBin,
                                           "Branch coverage ownership bins",
                                           $ownerBinDetailPage,
                                           scalar(@dataRow));
                push(@row_right, @$br_table);
            }
        }
    }

    # Print rows
    my $num_rows = max(scalar(@row_left), scalar(@row_right));
    for (my $i = 0; $i < $num_rows; $i++) {
        my $left  = $row_left[$i];
        my $right = $row_right[$i];

        if (!defined($left)) {
            $left = [[undef, undef, undef], [undef, undef, undef]];
        }
        if (!defined($right)) {
            $right = [];
        }
        write_header_line(*HTML_HANDLE, @{$left},
                          [$i == 0 ? "5%" : undef, undef, undef],
                          @{$right});
    }

    # Fourth line
    write_header_epilog(*HTML_HANDLE, $base_dir);
}

sub get_sort_code($$$)
{
    my ($link, $alt, $base) = @_;
    my $png;
    my $link_start;
    my $link_end;

    if (!defined($link)) {
        $png        = "glass.png";
        $link_start = "";
        $link_end   = "";
    } else {
        $png        = "updown.png";
        $link_start = '<a href="' . $link . '">';
        $link_end   = "</a>";
    }
    my $help = " title=\"Click to sort table by $alt\"";
    $alt = "Sort by $alt";
    return ' <span $help class="tableHeadSort">' .
        $link_start . '<img src="' . $base . $png . '" width=10 height=14 ' .
        'alt="' . $alt . '"' . $help . ' border=0>' . $link_end . '</span>';
}

sub get_file_code($$$$$$)
{
    my ($type, $text, $sort_button, $bin_type, $primary_key, $base) = @_;
    my $result = $text;
    my $link;

    my $key = 'name' ne $primary_key ? "-bin_$primary_key" : "";
    if ($sort_button) {
        $link = "index$key$bin_type";
        $link .= '-detail'
            unless ($type == $HEAD_NO_DETAIL);
        $link .= ".$html_ext";
    }
    $result .= get_sort_code($link, "file name", $base);

    return $result;
}

sub get_line_code($$$$$$$)
{
    my ($type, $sort_type, $text, $sort_button, $bin_type, $primary_key, $base)
        = @_;
    my $result = $text;
    my $sort_link;
    my $key = 'name' ne $primary_key ? "-bin_$primary_key" : "";

    if ($type == $HEAD_NO_DETAIL) {
        # Just text
        if ($sort_button) {
            $sort_link = "index" . $key . $bin_type . "-sort-l.$html_ext";
        }
    } elsif ($type == $HEAD_DETAIL_HIDDEN) {
        # Text + link to detail view
        my $help = "title=\"Click to show per-testcase coverage details\"";
        $result .=
            " ( <a $help " . 'class="detail" href="index' .
            $key . $bin_type . '-detail' . $fileview_sortname[$sort_type] .
            '.' . $html_ext . '">show details</a> )';
        if ($sort_button) {
            $sort_link = "index" . $bin_type . "-sort-l.$html_ext";
        }
    } else {
        # Text + link to standard view
        my $help = "title=\"Click to hide per-testcase coverage details\"";
        $result .=
            " ( <a $help " . 'class="detail" href="index' .
            $key . $bin_type . $fileview_sortname[$sort_type] .
            '.' . $html_ext . '">hide details</a> )';
        if ($sort_button) {
            $sort_link = "index" . $bin_type . "-detail-sort-l.$html_ext";
        }
    }
    # Add sort button
    $result .= get_sort_code($sort_link, "line coverage", $base);

    return $result;
}

sub get_func_code($$$$$$)
{
    my ($type, $text, $sort_button, $bin_type, $primary_key, $base) = @_;
    my $result = $text;
    my $link;
    my $key = 'name' ne $primary_key ? "-bin_$primary_key" : "";

    if ($sort_button) {
        $link = "index$key$bin_type";
        $link .= '-detail'
            unless ($type == $HEAD_NO_DETAIL);
        $link .= "-sort-f.$html_ext";
    }
    $result .= get_sort_code($link, "function coverage", $base);
    return $result;
}

sub get_br_code($$$$$$)
{
    my ($type, $text, $sort_button, $bin_type, $primary_key, $base) = @_;
    my $result = $text;
    my $link;
    my $key = 'name' ne $primary_key ? "-bin_$primary_key" : "";

    if ($sort_button) {
        $link = "index$key$bin_type";
        $link .= '-detail'
            unless ($type == $HEAD_NO_DETAIL);
        $link .= "-sort-b.$html_ext";
    }
    $result .= get_sort_code($link, "branch coverage", $base);
    return $result;
}

#
# write_file_table(filehandle, base_dir, perTestcaseData,
#                  parentSummary, ctrlSettings)
#   ctrlSettings = [fileview, sort_type, details_type, sort_name]
#   perTestcaseData = [testhash, testfnchash, testbrhash]
#
# Write a complete file table. OVERVIEW is a reference to a hash containing
# the following mapping:
#
#   filename -> "lines_found,lines_hit,funcs_found,funcs_hit,page_link,
#                func_link" + other file details
#
# TESTHASH is a reference to the following hash:
#
#   filename -> \%testdata
#   %testdata: name of test affecting this file -> \%testcount
#   %testcount: line number -> execution count for a single test
#
# Heading of first column is "Filename" if FILEVIEW is true, "Directory name"
# otherwise.
#

sub write_file_table(*$$$$)
{
    local *HTML_HANDLE = $_[0];
    my $base_dir        = $_[1];
    my $perTestcaseData = $_[2];    # undef or [lineCov, funcCov, branchCov]
    my $dirSummary      = $_[3];    # SummaryInfo object
    my ($fileview, $primary_key, $sort_type, $bin_type) = @{$_[4]};
    # $fileview == 0 if listing directories, 1 if listing files
    # $primary_key in ("name", "owner", "date"). If $primary_key is:
    #   - 'name': leftmost column is file/directory name -
    #     this is the original/vanilla genhtml behaviour
    #   - 'owner': leftmost column is author name.  Details for that owner
    #     (for all files in the project, or for all files in this drectory)
    #     are shown in a contiguous block.
    #   - 'date': leftmost column is date bin.  Details for that bin are
    #     shown in a contiguous block.
    # $sort_type in ("", "-sort-l", "-sort-b", "-sort-f")
    # $bin_type in ("", "-owner", "-date")
    #   - if $bin_type not "", expand non-empty entries after file/directory
    #     overall count (i.e. - show all the "owners" for this file/directory,
    #     or all date bins for this file/directory)
    #   - $bin_type is applied only if $primary_key is "name"

    $primary_key eq "name" || $bin_type eq "" or
        die(
        "primary key '$primary_key' does not support '$bin_type' detail reporting"
        );

    # Determine HTML code for column headings
    my $hide = $HEAD_NO_DETAIL;
    my $show = $HEAD_NO_DETAIL;
    if ($dirSummary->type() eq 'directory' && $show_details) {
        # "detailed" if line coverage hash not empty
        my $detailed =
            defined($perTestcaseData) && scalar(%{$perTestcaseData->[0]});
        $hide = $detailed ? $HEAD_DETAIL_HIDDEN : $HEAD_NO_DETAIL;
        $show = $detailed ? $HEAD_DETAIL_SHOWN : $HEAD_DETAIL_HIDDEN;
    }
    my $file_col_title =
        $fileview ? ('' eq $bin_type ? 'Filename' : 'File') : "Directory";
    my $file_code =
        get_file_code($hide, $file_col_title, $sort && $sort_type != $SORT_FILE,
                      $bin_type, $primary_key, $base_dir);
    my $line_code = get_line_code(
                             $show, $sort_type,
                             "Line Coverage", $sort && $sort_type != $SORT_LINE,
                             $bin_type, $primary_key,
                             $base_dir);
    my $func_code = get_func_code($hide,
                                  "Function Coverage",
                                  $sort && $sort_type != $SORT_FUNC,
                                  $bin_type, $primary_key, $base_dir);
    my $br_code = get_br_code($hide,
                              "Branch Coverage",
                              $sort && $sort_type != $SORT_BRANCH,
                              $bin_type, $primary_key, $base_dir);

    my @head_columns;

    my @lineCovCols     = (["coverage", 2], "Total");
    my @branchCovCols   = ("coverage", "Total");
    my @functionCovCols = ("coverage", "Total");
    if ($main::show_hitTotalCol) {
        my $t = $main::opt_missed ? "Missed" : "Hit";
        push(@lineCovCols, $t);
        push(@branchCovCols, $t);
        push(@functionCovCols, $t);
    }
    if ($main::show_tla) {
        my @col_details;
        foreach my $tla (@SummaryInfo::tlaPriorityOrder) {
            my $label =
                $main::use_legacyLabels ? $SummaryInfo::tlaToLegacy{$tla} :
                $tla;
            push(@col_details,
                 [$label,
                  1,
                  $main::use_legacyLabels ?
                      undef :
                      $SummaryInfo::tlaToTitle{$tla}
                 ]);
        }
        push(@lineCovCols, @col_details);
        push(@branchCovCols, @col_details);
        push(@functionCovCols, @col_details);
    }
    push(@head_columns, [$line_code, $#lineCovCols + 2, \@lineCovCols]);
    push(@head_columns, [$br_code, $#branchCovCols + 1, \@branchCovCols])
        if ($br_coverage);
    push(@head_columns, [$func_code, $#functionCovCols + 1, \@functionCovCols])
        if ($func_coverage);

    my $showBinDetail = undef;
    if ($bin_type eq '-date' &&
        $dirSummary &&
        $dirSummary->hasDateInfo()) {
        $showBinDetail = 'date';
    } elsif ($bin_type eq '-owner' &&
             $dirSummary &&
             $dirSummary->hasOwnerInfo()) {
        $showBinDetail = 'owner';
    }
    write_file_table_prolog(*HTML_HANDLE, $file_code,
                            defined($showBinDetail) ? $showBinDetail : undef,
                            $primary_key, @head_columns);

    my @tableRows;
    if ($primary_key eq 'name') {

        # sorted list of all the file or directory names
        foreach my $name ($dirSummary->get_sorted_keys($sort_type, 1)) {
            my $entrySummary = $dirSummary->get_source($name);

            if ($entrySummary->type() eq 'directory') {
                if ('directory' eq $dirSummary->type()) {
                    $name = File::Basename::basename($name);
                } elsif ($entrySummary->is_directory(1)) {
                    $name = '/' . $name;
                }
            } else {
                die("unexpected summary type")
                    unless 'file' eq $entrySummary->type();
                $name = File::Basename::basename($name);
            }
            push(@tableRows,
                 FileOrDirectoryCallback->new($name, $entrySummary));
        }

    } elsif ($primary_key eq 'owner') {

        # retrieve sorted list of owner names - alphabetically, by name
        #   or by number of missed lines or missed branches
        my $all = defined($main::show_ownerBins) && $main::show_ownerBins;

        # line coverage...
        my %owners;
        foreach my $owner ($dirSummary->owners($all, 'line')) {

            $owners{$owner} = [
                               [$dirSummary->owner_tlaCount($owner, 'found'),
                                $dirSummary->owner_tlaCount($owner, 'hit')
                               ],
                               [0, 0],    # no branch owner data
                               [0, 0],    # no function owner
            ];
        }
        if ($br_coverage) {
            foreach my $owner ($dirSummary->owners($all, 'branch')) {

                $owners{$owner} = [[0, 0], [0, 0], [0, 0]]
                    unless exists($owners{$owner});

                $owners{$owner}->[1] = [
                         $dirSummary->owner_tlaCount($owner, 'found', 'branch'),
                         $dirSummary->owner_tlaCount($owner, 'hit', 'branch')
                ];
            }
        }
        my @sorted;
        # now, sort the owner list...
        if ($sort_type eq $SORT_LINE) {
            # sort by number of missed lines
            @sorted = sort({
                               my $la = $owners{$a}->[0];
                               my $lb = $owners{$b}->[0];
                               ($lb->[0] - $lb->[1]) <=> ($la->[0] - $la->[1])
                                   ||
                                   $a cmp $b    # then by name
            } keys(%owners));
        } elsif ($sort_type eq $SORT_BRANCH) {
            # sort by number of missed branches
            @sorted = sort({
                               my $la = $owners{$a}->[1];
                               my $lb = $owners{$b}->[1];
                               ($lb->[0] - $lb->[1]) <=> ($la->[0] - $la->[1])
                                   ||
                                   $a cmp $b    # then by name
            } keys(%owners));
        } else {
            @sorted = sort(keys(%owners));
        }
        foreach my $owner (@sorted) {
            push(@tableRows,
                 FileOrDirectoryOwnerCallback->new($owner, $dirSummary));
        }

    } elsif ($primary_key eq 'date') {

        for (my $bin = 0; $bin <= $#SummaryInfo::ageGroupHeader; ++$bin) {
            my $ageval = $dirSummary->age_sample($bin);
            my $lines  = $dirSummary->lineCovCount('found', 'age', $ageval);
            if (0 != $lines ||
                ($br_coverage &&
                    0 != $dirSummary->branchCovCount('found', 'age', $ageval))
                ||
                ($func_coverage &&
                    0 != $dirSummary->functionCovCount('found', 'age', $ageval))
            ) {
                push(@tableRows,
                     FileOrDirectoryDateCallback->new($bin, $dirSummary));
            }
        }
    } else {
        die("unsupported primary key '$primary_key'");
    }

    my $all = defined($main::show_ownerBins) && $main::show_ownerBins eq 'all';
    my $useAsterisk = 0;
    if ($primary_key eq 'owner') {
        $useAsterisk = $main::show_ownerBins ne 'all';
    } elsif ($primary_key eq 'date') {
        $useAsterisk = 1;
    }
    my $needAsterisk = 0;
    my $asterisk_note =
        "<sup>&lowast;</sup> 'Detail' entries with no 'missed' coverpoints are elided.";

    foreach my $primaryCb (@tableRows) {

        # we need to find the 'owner' and 'date' row data for this file before
        #   we write anything else, because we need to know the number of
        #   rows that the $primary cell will span

        my @secondaryRows;

        if (defined($showBinDetail)) {

            if (defined($primaryCb->summary())) {
                my $source = $primaryCb->summary();

                if ($showBinDetail eq 'owner') {
                    # do I need an option to suppress the list of owners?
                    #  maybe too much information, in some circumstances?
                    # are there any non-empty owner tables here?
                    my $ownerList = $primaryCb->findOwnerList($all);
                    push(@secondaryRows, @$ownerList)
                        if defined($ownerList);
                }

                if ($showBinDetail eq 'date') {
                    for (my $bin = 0;
                         $bin <= $#SummaryInfo::ageGroupHeader;
                         ++$bin) {
                        my $ageval = $source->age_sample($bin);
                        my $lineCb =
                            $primaryCb->dateDetailCallback($ageval, 'line');
                        my $lineTotal  = $lineCb->get('found');
                        my $hit        = $lineCb->get('hit');
                        my $lineMissed = $lineTotal - $hit;

                        my $branchCb =
                            $primaryCb->dateDetailCallback($ageval, 'branch');
                        my $branchTotal =
                            $br_coverage ? $branchCb->get('found') : 0;
                        $hit = $br_coverage ? $branchCb->get('hit') : 0;
                        my $branchMissed = $branchTotal - $hit;

                        my $functionCb =
                            $primaryCb->dateDetailCallback($ageval, 'function');
                        my $functionTotal =
                            $func_coverage ? $functionCb->get('found') : 0;
                        $hit = $func_coverage ? $functionCb->get('hit') : 0;
                        my $functionMissed = $functionTotal - $hit;

                        next
                            if 0 == $lineTotal &&
                            0 == $branchTotal  &&
                            0 == $functionTotal;

                        push(@secondaryRows,
                             [$SummaryInfo::ageGroupHeader[$bin],
                              [$lineMissed, $lineTotal, $lineCb],
                              [$branchMissed, $branchTotal, $branchCb],
                              [$functionMissed, $functionTotal, $functionCb]
                             ]);
                    }
                }
            }
        }    # if showBinDetail
        elsif ($primary_key ne 'name') {
            push(@secondaryRows, $primaryCb->findFileList($all));
        }

        my ($found, $hit, $fn_found,
            $fn_hit, $br_found, $br_hit,
            $page_link, $fileSummary, $fileDetails) = $primaryCb->data();
        # a bit of a hack: if this is top-level page (such that the links
        #   are to directory pages rather than to source code detail pages)
        #   and this is the 'owner bin detail' (or the 'date bin detail') view,
        #   then link to the same 'bin detail' view of the directory page
        # This enables the user who is tracking down code written by a
        #   particular user (or on a particular date) to go link-to-link
        #   without having to select the 'bin' link in the destination header.
        if ($fileview == 0 &&
            $bin_type ne "") {
            $page_link =~ s/index.$html_ext$/index$bin_type.$html_ext/;
        }

        my @columns;

        my @tableCallbackData = ($primaryCb->name(), $fileDetails, $page_link);
        my $showLineGraph     = 1;
        # Line coverage
        push(@columns,
             [$found, $hit, $med_limit, $hi_limit, $showLineGraph,
              $primaryCb->totalCallback('line'), 'line'
             ]);
        # Branch coverage
        if ($br_coverage) {
            push(@columns,
                 [$br_found, $br_hit, $br_med_limit, $br_hi_limit, 0,
                  $primaryCb->totalCallback('branch'), 'branch'
                 ]);
        }
        # Function coverage
        if ($func_coverage) {
            # no 'owner' callbacks for function...
            my $cbStruct = $primaryCb->totalCallback('function')
                if ('owner' ne $primary_key);
            push(@columns,
                 [$fn_found, $fn_hit, $fn_med_limit, $fn_hi_limit,
                  0, $cbStruct, 'function'
                 ]);
        }
        # pass 'dirSummary' to print method:  we omit the 'owner' column if
        #  none of the files in this directory have any owner information
        #  (i.e., none of them are found in the repo)
        my $numRows = (1 + scalar(@secondaryRows));
        my $asterisk;
        if ($useAsterisk && 1 == $numRows) {
            $asterisk     = '*';
            $needAsterisk = 1;
        }
        write_file_table_entry(*HTML_HANDLE,
                               $base_dir,
                               [$primaryCb->name(), \@tableCallbackData,
                                $numRows, $primary_key,
                                0, $fileview,
                                "fileOrDir", $page_link,
                                $dirSummary, $showBinDetail,
                                $asterisk
                               ],
                               @columns);

        # sort secondary rows...
        if ($sort_type == $SORT_FILE) {
            # alphabetic
            @secondaryRows = sort({ $a->[0] cmp $b->[0] } @secondaryRows);
        } else {
            my $sortElem;
            if ($sort_type == $SORT_LINE) {
                $sortElem = 1;
            } elsif ($sort_type == $SORT_BRANCH) {
                $sortElem = 2;
            } elsif ($sort_type == $SORT_FUNC) {
                $sortElem = 3;
            }
            @secondaryRows =
                sort({
                         my $ca = $a->[$sortElem];
                         my $cb = $b->[$sortElem];
                         # sort based on 'missed'
                         $cb->[0] <=> $ca->[0];
                } @secondaryRows);
        }
        foreach my $secondary (@secondaryRows) {
            my ($name, $line, $branch, $func) = @$secondary;
            my ($lineMissed, $lineTotal, $lineCb) = @$line;
            my $lineHit = $lineTotal - $lineMissed;

            my $fileInfo = $primaryCb->secondaryElementFileData($name);

            my $entry_type = $lineCb->cb_type();

            my @ownerColData;
            push(@ownerColData,
                 [$lineTotal, $lineHit, $med_limit, $hi_limit,
                  $showLineGraph, $lineCb, 'line'
                 ]);
            if ($br_coverage) {
                my ($branchMissed, $branchTotal, $brCallback) = @$branch;
                # need to compute the totals...
                push(@ownerColData,
                     [$branchTotal, $branchTotal - $branchMissed,
                      $br_med_limit, $br_hi_limit,
                      0, $brCallback,
                      'branch'
                     ]);
            }
            if ($func_coverage) {
                my ($funcMissed, $funcTotal, $funcCallback) = @$func;
                # need to compute the totals...
                push(@ownerColData,
                     [$funcTotal, $funcTotal - $funcMissed,
                      $fn_med_limit, $fn_hi_limit,
                      0, $funcCallback,
                      'function'
                     ]);
            }
            if ($dirSummary->type() eq 'directory') {
                # use the basename (not the path or full path) in the
                #  secondary key list:
                #  - these are files in the current directory, so we lose
                #    no information by eliding the directory part
                $name = File::Basename::basename($name);
            }
            write_file_table_entry(*HTML_HANDLE, $base_dir,
                                   # 'owner' page type - no span, no page link
                                   [$name, $fileInfo,
                                    1, $primary_key,
                                    1, $fileview,
                                    $entry_type
                                   ],
                                   @ownerColData);
        }

        next
            unless ($show_details &&
                    defined($perTestcaseData) &&
                    $primary_key eq "name");

        # we know that the top-level callback item must hold a file.
        my $filename = $primaryCb->name();

        my ($testhash, $testfnchash, $testbrhash) = @$perTestcaseData;

        my $testdata = $testhash->{$filename};

        # Check whether we should write test specific coverage as well
        next if (!defined($testdata));

        my $testfncdata = $testfnchash->{$filename};
        my $testbrdata  = $testbrhash->{$filename};

        # Filter out those tests that actually affect this file
        my %affecting_tests =
            %{get_affecting_tests($testdata, $testfncdata, $testbrdata)};

        # Does any of the tests affect this file at all?
        if (!%affecting_tests) { next; }

        foreach my $testname (keys(%affecting_tests)) {

            ($found, $hit, $fn_found, $fn_hit, $br_found, $br_hit) =
                @{$affecting_tests{$testname}};

            my $showgraph = 0;
            my @results;
            push(@results,
                 [$found, $hit, 'line',
                  TestcaseTlaCount->new(
                                      $testdata->value($testname), $fileDetails,
                                      'line')
                 ]);
            push(@results,
                 [$br_found,
                  $br_hit, 'branch',
                  TestcaseTlaCount->new(
                                    $testbrdata->value($testname), $fileDetails,
                                    'branch')
                 ]) if ($br_coverage);
            push(@results,
                 [$fn_found,
                  $fn_hit,
                  'function',
                  TestcaseTlaCount->new(
                                   $testfncdata->value($testname), $fileDetails,
                                   'function')
                 ]) if ($func_coverage);

            my $href = $testname;
            # Insert link to description of available
            if ($test_description{$testname}) {
                $href = "<a href=\"$base_dir" .
                    "descriptions.$html_ext#$testname\">" . "$testname</a>";
            }
            write_file_table_detail_entry(*HTML_HANDLE, $base_dir,
                                          $href, $showBinDetail, @results);
        }
    }

    write_file_table_epilog(*HTML_HANDLE);
    if ($needAsterisk) {
        write_html(*HTML_HANDLE, "$asterisk_note\n");
    }
}

#
# get_affecting_tests(testdata, testfncdata, testbrdata)
#
# HASHREF contains a mapping filename -> (linenumber -> exec count). Return
# a hash containing mapping filename -> "lines found, lines hit" for each
# filename which has a nonzero hit count.
#

sub get_affecting_tests($$$)
{
    my ($testdata, $testfncdata, $testbrdata) = @_;
    my %result;

    foreach my $testname ($testdata->keylist()) {
        # Get (line number -> count) hash for this test case
        my $testcount    = $testdata->value($testname);
        my $testfnccount = $testfncdata->value($testname);
        my $testbrcount  = $testbrdata->value($testname);

        # Calculate sum
        my ($found, $hit)       = $testcount->get_found_and_hit();
        my ($fn_found, $fn_hit) = $testfnccount->get_found_and_hit();
        my ($br_found, $br_hit) = $testbrcount->get_found_and_hit();

        $result{$testname} =
            [$found, $hit, $fn_found, $fn_hit, $br_found, $br_hit]
            if ($hit > 0);
    }
    return (\%result);
}

#
# write_source(filehandle, source_filename, count_data, checksum_data,
#              converted_data, func_data, sumbrcount)
#
# Write an HTML view of a source code file. Returns a list containing
# data as needed by gen_png().
#
# Die on error.
#

sub write_source($$$$$$$)
{
    local *HTML_HANDLE = shift;
    my ($srcfile, $count_data, $checkdata, $fileCovInfo, $funcdata, $sumbrcount)
        = @_;
    my @result;

    write_source_prolog(*HTML_HANDLE, $srcfile->isProjectFile());
    my $line_number = 0;
    my $cbdata      = PrintCallback->new($srcfile, $fileCovInfo);

    foreach my $srcline (@{$srcfile->lines()}) {
        $line_number++;
        $cbdata->lineNo($line_number);

        # Source code matches coverage data?
        die("ERROR: checksum mismatch  at " .
            $srcfile->path() . ":$line_number\n")
            if (
               defined($checkdata->value($line_number)) &&
               ($checkdata->value($line_number) ne md5_base64($srcline->text()))
            );
        push(@result,
             write_source_line(HTML_HANDLE,
                               $srcline,
                               $count_data->value($line_number),
                               $sumbrcount->value($line_number),
                               $cbdata));
    }
    write_source_epilog(*HTML_HANDLE);
    return (@result);
}

sub funcview_get_func_code($$$)
{
    my ($name, $base, $type) = @_;
    my $link;

    if ($sort && $type == 1) {
        $link = "$name.func.$html_ext";
    }
    my $result =
        "Function Name" . get_sort_code($link, "Sort by function name", $base);
    return $result;
}

sub funcview_get_count_code($$$)
{
    my ($name, $base, $type) = @_;
    my $link;

    if ($sort && $type == 0) {
        $link = "$name.func-sort-c.$html_ext";
    }
    my $result = "Hit count" . get_sort_code($link, "Sort by hit count", $base);
    return $result;
}

#
# funcview_get_sorted(funcdata, sort_type, mergedView)
#
# Depending on the value of sort_type, return a list of functions sorted
# by name (type 0) or by the associated call count (type 1).
#

sub funcview_get_sorted($$$)
{
    my ($differential_func, $type, $merged) = @_;

    my @rtn = keys(%$differential_func);

    if ($type != 0) {
        @rtn = sort({
                        my $da = $differential_func->{$a}->hit();
                        my $db = $differential_func->{$b}->hit();
                        $da->[0] <=> $db->[0] or
                            # sort by function name if count matches
                            $a cmp $b
        } @rtn);
    } elsif (!defined($main::no_sort)) {
        # sort alphabetically by function name
        @rtn = sort(@rtn);
    }
    return @rtn;
}

#
# write_function_table(filehandle, differentialMap, source_file, sumcount, funcdata,
#                      testfncdata, sumbrcount, testbrdata,
#                      base_name, base_dir, sort_type)
#
# Write an HTML table listing all functions in a source file, including
# also function call counts and line coverages inside of each function.
#
# Die on error.
#

sub write_function_table(*$$$$$$$$$$)
{
    local *HTML_HANDLE = shift;
    my ($differentialMap, $source, $sumcount, $funcdata,
        $testfncdata, $sumbrcount, $testbrdata, $name,
        $base, $type) = @_;

    # Get HTML code for headings
    my $func_code  = funcview_get_func_code($name, $base, $type);
    my $count_code = funcview_get_count_code($name, $base, $type);
    my $showTlas   = $main::show_tla && 0 != scalar(keys %$differentialMap);
    my $tlaRow     = "";
    my $countWidth = 20;
    if ($showTlas) {
        my $label = $main::use_legacyLabels ? 'Hit?' : 'TLA';
        $tlaRow     = "<td width=\"10%\" class=\"tableHead\">$label</td>";
        $countWidth = 10;
    }
    write_html(*HTML_HANDLE, <<END_OF_HTML);
          <center>
          <table width="60%" cellpadding=1 cellspacing=1 border=0>
            <tr><td><br></td></tr>
            <tr>
              <td width="80%" class="tableHead">$func_code</td>
              $tlaRow
              <td width="${countWidth}%" class="tableHead">$count_code</td>
            </tr>
END_OF_HTML

    my $merged =
        defined($lcovutil::cov_filter[$lcovutil::FILTER_FUNCTION_ALIAS]);
    foreach my $func (funcview_get_sorted($differentialMap, $type, $merged)) {

        my $funcEntry = $differentialMap->{$func};
        my ($count, $tla) = @{$funcEntry->hit()};
        next if 'D' eq substr($tla, 0, 1);    # don't display deleted functions
        my $startline = $funcEntry->line() - $func_offset;
        my $name      = $func;
        my $countstyle;

        # Escape special characters
        $name = escape_html($name);
        if ($startline < 1) {
            $startline = 1;
        }
        if ($count == 0) {
            $countstyle = "coverFnLo";
        } else {
            $countstyle = "coverFnHi";
        }
        my $tlaRow = "";
        if ($showTlas) {
            my $label =
                $main::use_legacyLabels ? $SummaryInfo::tlaToLegacy{$tla} :
                $tla;
            $tlaRow = "<td class=\"tla$tla\">$label</td>";
        }
        write_html(*HTML_HANDLE, <<END_OF_HTML);
            <tr>
              <td class="coverFn"><a href="$source#$startline">$name</a></td>
              $tlaRow
              <td class="$countstyle">$count</td>
            </tr>
END_OF_HTML

        if ($funcEntry->numAliases() > 1) {
            my $aliases   = $funcEntry->aliases();
            my @aliasList = keys(%$aliases);
            if (0 != $type) {
                @aliasList =
                    sort({
                             my $da = $aliases->{$a};
                             my $db = $aliases->{$b};
                             $da->[0] <=> $db->[0] or $a cmp $b
                    } @aliasList);
            } else {
                @aliasList = sort(@aliasList);
            }
            foreach my $alias (@aliasList) {
                my ($hit, $tla) = @{$aliases->{$alias}};
                # don't display deleted functions
                next
                    if 'D' eq substr($tla, 0, 1);
                my $style = "coverFnAlias" . ($hit == 0 ? "Lo" : "Hi");
                $tlaRow = "";
                if ($showTlas) {
                    my $label =
                        $main::use_legacyLabels ?
                        $SummaryInfo::tlaToLegacy{$tla} :
                        $tla;
                    $tlaRow = "<td class=\"tla$tla\">$label</td>";
                }
                write_html(*HTML_HANDLE, <<END_OF_HTML);
            <tr>
              <td class="coverFnAlias"><a href="$source#$startline">$alias</a></td>
              $tlaRow
              <td class="$style">$hit</td>
            </tr>
END_OF_HTML
            }
        }
    }
    write_html(*HTML_HANDLE, <<END_OF_HTML);
          </table>
          <br>
          </center>
END_OF_HTML
}

#
# remove_unused_descriptions()
#
# Removes all test descriptions from the global hash %test_description which
# are not present in %current_data.
#

sub remove_unused_descriptions()
{
    my $filename;     # The current filename
    my %test_list;    # Hash containing found test names
    my $test_data;    # Reference to hash test_name -> count_data
    my $before;       # Initial number of descriptions
    my $after;        # Remaining number of descriptions

    $before = scalar(keys(%test_description));

    foreach $filename ($current_data->files()) {
        ($test_data) = $current_data->data($filename)->get_info();
        foreach ($test_data->keylist()) {
            $test_list{$_} = "";
        }
    }

    # Remove descriptions for tests which are not in our list
    foreach (keys(%test_description)) {
        if (!defined($test_list{$_})) {
            delete($test_description{$_});
        }
    }

    $after = scalar(keys(%test_description));
    if ($after < $before) {
        info("Removed " . ($before - $after) .
             " unused descriptions, $after remaining.\n");
    }
}

#
# apply_prefix(filename, PREFIXES)
#
# If FILENAME begins with PREFIX from PREFIXES, remove PREFIX from FILENAME
# and return resulting string, otherwise return FILENAME.
#

sub apply_prefix($@)
{
    my $filename   = shift;
    my @dir_prefix = @_;

    if (@dir_prefix) {
        foreach my $prefix (@dir_prefix) {
            if ($prefix eq $filename) {
                return "root";
            }
            if ($prefix ne "" && $filename =~ /^\Q$prefix\E\/(.*)$/) {
                return substr($filename, length($prefix) + 1);
            }
        }
    }

    return $filename;
}

#
# get_html_prolog(FILENAME)
#
# If FILENAME is defined, return contents of file. Otherwise return default
# HTML prolog. Die on error.
#

sub get_html_prolog($)
{
    my $filename = $_[0];
    my $result   = "";

    if (defined($filename)) {
        local *HANDLE;

        open(HANDLE, "<", $filename) or
            die("ERROR: cannot open html prolog $filename!\n");
        while (<HANDLE>) {
            $result .= $_;
        }
        close(HANDLE);
    } else {
        $result = <<END_OF_HTML;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">

<html lang="en">

<head>
  <meta http-equiv="Content-Type" content="text/html; charset=$charset">
  <title>\@pagetitle\@</title>
  <link rel="stylesheet" type="text/css" href="\@basedir\@gcov.css">
</head>

<body>

END_OF_HTML
    }
    return $result;
}

#
# get_html_epilog(FILENAME)
#
# If FILENAME is defined, return contents of file. Otherwise return default
# HTML epilog. Die on error.
#
sub get_html_epilog($)
{
    my $filename = $_[0];
    my $result   = "";

    if (defined($filename)) {
        local *HANDLE;

        open(HANDLE, "<", $filename) or
            die("ERROR: cannot open html epilog $filename!\n");
        while (<HANDLE>) {
            $result .= $_;
        }
        close(HANDLE);
    } else {
        $result = <<END_OF_HTML;

</body>
</html>
END_OF_HTML
    }

    return $result;
}

#
# parse_dir_prefix(@dir_prefix)
#
# Parse user input about the prefix list
#

sub parse_dir_prefix(@)
{
    my (@opt_dir_prefix) = @_;

    return if (!@opt_dir_prefix);

    foreach my $item (@opt_dir_prefix) {
        if ($item =~ /,/) {
            # Split and add comma-separated parameters
            push(@dir_prefix, split(/,/, $item));
        } else {
            # Add single parameter
            push(@dir_prefix, $item);
        }
    }
}