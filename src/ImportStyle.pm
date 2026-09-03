#    Copyright (c) 2009 Erland Isaksson (erland_i@hotmail.com)
# 
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
package Plugins::CustomClockHelper::ImportStyle;

use strict;
use base qw(Plugins::CustomClockHelper::BaseSettings);

use File::Basename;
use File::Next;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;

use Data::Dumper;
use JSON::XS;
use Encode qw(encode_utf8);

my $prefs = preferences('plugin.customclockhelper');
my $log   = logger('plugin.customclockhelper');

my $plugin; # reference to main plugin

sub new {
	my $class = shift;
	$plugin   = shift;

	$class->SUPER::new($plugin);
}

sub name {
	return 'SETUP_PLUGIN_CUSTOMCLOCKHELPER_SETTINGS_IMPORT';
}

sub page {
	return 'plugins/CustomClockHelper/settings/importstyle.html';
}

sub currentPage {
	my ($class, $client, $params) = @_;
	return Slim::Utils::Strings::string('PLUGIN_CUSTOMCLOCKHELPER_STYLESETTINGS')." ".Slim::Utils::Strings::string('SETUP_PLUGIN_CUSTOMCLOCKHELPER_SETTINGS_IMPORT');
}

sub pages {
	my ($class, $client, $params) = @_;
	my @pages = ();
	my %page = (
		'name' => Slim::Utils::Strings::string('PLUGIN_CUSTOMCLOCKHELPER_STYLESETTINGS')." ".Slim::Utils::Strings::string('SETUP_PLUGIN_CUSTOMCLOCKHELPER_SETTINGS_IMPORT'),
		'page' => page(),
	);
	push @pages,\%page;
	return \@pages;
}

sub handler {
	my ($class, $client, $params) = @_;

	my $style = undef;
	if(defined($params->{'saveSettings'})) {
		$style = saveHandler($class, $client, $params);
	}
	return $class->SUPER::handler($client, $params);
}

sub saveHandler {
	my ($class, $client, $params) = @_;

	my $text = $params->{'text'};

	if(defined($text) && $text ne "") {
		# Robust UTF-8 handling for JSON::XS
		# Normalize input to UTF-8 bytes for consistent JSON decoding
		# If text has the UTF-8 flag set (Perl internal characters), 
		# encode it to UTF-8 bytes. Otherwise, assume it's already bytes.
		my $text_bytes = utf8::is_utf8($text) ? encode_utf8($text) : $text;
		
		my $style;
		eval {
			# Always use decode_json with UTF-8 bytes for consistent behavior
			$style = JSON::XS::decode_json($text_bytes);
		};
		if ($@) {
			$log->error("Failed to parse JSON style data: $@");
			$params->{'importError'} = Slim::Utils::Strings::string('SETUP_PLUGIN_CUSTOMCLOCKHELPER_SETTINGS_IMPORT_INVALID_JSON');
			return undef;
		}
		
		my $validItems = ref($style) eq 'HASH' && ref($style->{'items'}) eq 'ARRAY';
		if($validItems) {
			for my $item (@{$style->{'items'}}) {
				# The applet matches item.itemtype against string patterns at
				# dozens of call sites without a nil/type guard, so a missing
				# or non-scalar itemtype crashes the whole screen instead of
				# just being skipped -- reject it here instead.
				if(ref($item) ne 'HASH' || !defined($item->{'itemtype'}) || ref($item->{'itemtype'}) || $item->{'itemtype'} eq '') {
					$validItems = 0;
					last;
				}
			}
		}
		if(ref($style) eq 'HASH' && defined($style->{'name'}) && $style->{'name'} ne '' && ref($style->{'models'}) eq 'ARRAY' && $validItems) {
			# Use the same canonical key builder as everywhere else
			# (getStyleKey - sorts models alphabetically, and re-validates
			# models/name more strictly than the checks above, e.g. rejects
			# a non-string model or a reference-valued name) instead of
			# concatenating models in whatever order the source JSON used -
			# a mismatched key here breaks later lookups by StyleSettings.pm
			# (which populates its "current style" field via getStyleKey()).
			# No fallback to the raw name: getStyles() only ever recognizes
			# a style by its canonical getStyleKey() value, so saving under
			# anything else would make the import "succeed" while the style
			# silently fails to show up afterwards.
			my $styleName = Plugins::CustomClockHelper::Plugin::getStyleKey($style);
			if(defined($styleName)) {
				Plugins::CustomClockHelper::Plugin->setStyle($client,$styleName,$style);
				return $style;
			}
		}
		$log->error("Invalid JSON style data: expected a named style with models and an array of item objects");
		$params->{'importError'} = Slim::Utils::Strings::string('SETUP_PLUGIN_CUSTOMCLOCKHELPER_SETTINGS_IMPORT_INVALID_STYLE');
	}else {
		$params->{'importError'} = Slim::Utils::Strings::string('SETUP_PLUGIN_CUSTOMCLOCKHELPER_SETTINGS_IMPORT_EMPTY');
	}
	return undef;
}

# other people call us externally.
*escape   = \&URI::Escape::uri_escape_utf8;
		
1;
