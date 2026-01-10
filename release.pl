#!/usr/bin/perl
# Usage: release.pl <repofile> <version> <zipfile> <url> <name>
#   repofile: Path to repo.xml file
#   version:  Version string (e.g., "1.0.0")
#   zipfile:  Path to zip file to calculate SHA for
#   url:      Base URL (zip filename will be appended)
#   name:     Applet name identifier (e.g., "CustomClockHelper")
#
# Examples:
#   perl release.pl repo.xml 1.0.0 CustomClockHelper.zip http://example.com CustomClockHelper
#   perl release.pl repo.xml 2.0.0 JLJiveApplet.zip http://example.com JLJiveApplet

use strict;

use XML::Simple;
use File::Basename;
use Digest::SHA;

my $repofile = $ARGV[0];
my $version = $ARGV[1];
my $zipfile = $ARGV[2];
my $url = $ARGV[3];
my $name = $ARGV[4];

# Name parameter is required
if (!defined $name || $name eq '') {
    die "Error: Applet name parameter is required\n";
}

my $repo = XMLin($repofile, ForceArray => 1, KeepRoot => 0, KeyAttr => 0, NoAttr => 0);

# Ensure applets section exists
if (!exists $repo->{applets}) {
    $repo->{applets} = [{ applet => [] }];
} elsif (!exists $repo->{applets}[0]->{applet}) {
    $repo->{applets}[0]->{applet} = [];
}

# Find the applet with matching name, or create new one
my $applet_index = -1;
my $applets = $repo->{applets}[0]->{applet};

for (my $i = 0; $i < scalar(@$applets); $i++) {
    if (exists $applets->[$i]->{name} && $applets->[$i]->{name} eq $name) {
        $applet_index = $i;
        last;
    }
}

# If not found, add new applet entry
if ($applet_index == -1) {
    push @$applets, { name => $name };
    $applet_index = scalar(@$applets) - 1;
}

# Calculate SHA
open (my $fh, "<", $zipfile) or die $!;
binmode $fh;

my $digest = Digest::SHA->new;
$digest->addfile($fh);
close $fh;

# Update the applet entry
$applets->[$applet_index]->{name} = $name;
$applets->[$applet_index]->{version} = $version;
$applets->[$applet_index]->{sha}[0] = $digest->hexdigest;
$url .= "/$zipfile";
$applets->[$applet_index]->{url}[0] = $url;

print("name   : $name\n");
print("version: $version\n");
print("sha    : ", $digest->hexdigest, "\n");
print("url    : $url\n");

XMLout($repo, RootName => 'extensions', NoSort => 1, XMLDecl => 1, KeyAttr => '', OutputFile => $repofile, NoAttr => 0);


