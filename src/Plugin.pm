# 				Custom Clock Helper plugin 
#
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

use strict;
use warnings;
                   
package Plugins::CustomClockHelper::Plugin;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Prefs;

use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::Strings qw(string);

use LWP::UserAgent;
use JSON::XS;
use Data::Dumper;

use Plugins::CustomClockHelper::StyleSettings;
use Plugins::CustomClockHelper::ImportStyle;
use Plugins::CustomClockHelper::Settings;

my $prefs = preferences('plugin.customclockhelper');
my $serverPrefs = preferences('server');
my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.customclockhelper',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_CUSTOMCLOCKHELPER',
});

my $PLUGINVERSION = undef;

$prefs->migrate(1,sub {
	my @empty = ();
	$prefs->set('titleformats',\@empty)
});

my $customItems = {};
my $refreshCustomItems = undef;
my $customItemProviders = {};
my $refreshGeneration = 0;
my $customItemRefreshTimeout = 60;

$prefs->migrate(2, sub {
	$prefs->set('customitemsstartuprefreshinterval', 60);
	$prefs->set('customitemsrefreshinterval', 300);
	1;
});

# Timer intervals are user-editable text fields; reject non-numeric,
# negative or too-small values instead of feeding them straight into
# Time::HiRes arithmetic, where e.g. a negative value would fire immediately
# and repeatedly (a tight refresh loop hammering providers/LMS).
sub _getValidatedInterval {
	my $prefName = shift;
	my $default = shift;
	my $minimum = shift;
	$minimum = 0 if !defined($minimum);

	my $value = $prefs->get($prefName);
	if(!defined($value) || $value !~ /^\d+(?:\.\d+)?$/ || $value < $minimum) {
		return $default;
	}
	return $value;
}

sub getDisplayName()
{
	return string('PLUGIN_CUSTOMCLOCKHELPER'); 
}

sub initPlugin
{
	my $class = shift;
	$class->SUPER::initPlugin(@_);
	_migrateLocalStyleKeysToCanonical();
	Plugins::CustomClockHelper::ImportStyle->new($class);
	Plugins::CustomClockHelper::StyleSettings->new($class);
	Plugins::CustomClockHelper::Settings->new($class);
	$PLUGINVERSION = Slim::Utils::PluginManager->dataForPlugin($class)->{'version'};
	Slim::Control::Request::addDispatch(['customclock','styles'], [0, 1, 0, \&getClockStyles]);
	Slim::Control::Request::addDispatch(['customclock', 'titleformats'],[0, 1, 0, \&getTitleFormats]);
	Slim::Control::Request::addDispatch(['customclock', 'customitems'],[0, 1, 0, \&getCustomItems]);
	Slim::Control::Request::addDispatch(['customclock', 'refreshcustomitems'],[0, 1, 0, \&refreshCustomItemsCommand]);
	Slim::Control::Request::addDispatch(['customclockchangedstyles'],[0, 1, 0, undef]);
	Slim::Control::Request::addDispatch(['customclocktitleformatsupdated'],[0, 1, 0, undef]);
	Slim::Control::Request::addDispatch(['customclockchangedcustomitems'],[0, 1, 0, undef]);
	$class->webPages();
	Slim::Control::Request::subscribe(\&changedSong,[['playlist'],['newsong','delete','clear']]);
	Slim::Control::Request::subscribe(\&changedRating,[['trackstat'],['changedrating']]);
	${Slim::Music::Info::suffixes}{'binfile'} = 'binfile';
	${Slim::Music::Info::types}{'binfile'} = 'application/octet-stream';
}

sub shutdownPlugin {
	Slim::Utils::Timers::killTimers(undef, \&refreshCustomItems);
	Slim::Utils::Timers::killTimers(undef, \&refreshNextProvider);
	for my $id (keys %$customItemProviders) {
		if($customItemProviders->{$id}->{refreshTimeoutCallback}) {
			Slim::Utils::Timers::killTimers(undef, $customItemProviders->{$id}->{refreshTimeoutCallback});
			delete $customItemProviders->{$id}->{refreshTimeoutCallback};
		}
	}
	Slim::Control::Request::unsubscribe(\&changedSong);
	Slim::Control::Request::unsubscribe(\&changedRating);
	$refreshCustomItems = undef;
}

sub postinitPlugin {
	my $interval = _getValidatedInterval('customitemsstartuprefreshinterval', 60, 0);
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + ($interval), \&refreshCustomItems);
}

sub addCustomClockCustomItemProvider {
	my $id = shift;
	my $name = shift;
	my $callback = shift;
	
	$customItemProviders->{$id} = {
		name => $name,
		callback => $callback,
	};
}

sub addingCustomItems {
	my $reference = shift;
	my $items = shift;
	my $generation = shift;
	my $provider = $customItemProviders->{$reference};
	if(!defined($refreshCustomItems) || !defined($provider) || !$provider->{refreshing} || (defined($generation) && $provider->{refreshGeneration} != $generation)) {
		$log->warn("Ignoring stale custom item refresh result from $reference");
		return;
	}
	if($provider->{refreshTimeoutCallback}) {
		Slim::Utils::Timers::killTimers(undef, $provider->{refreshTimeoutCallback});
		delete $provider->{refreshTimeoutCallback};
	}
	if(ref($items) ne 'HASH') {
		$log->error("Invalid custom item refresh result from $reference");
		$provider->{refreshError} = 1;
	}

	if($provider->{refreshError}) {
		# Keep whatever data we already committed for this provider instead
		# of replacing it with an empty/malformed result.
		$log->warn("Refresh failed for $reference, keeping last-known-good data");
	}else {
		$log->info("Got refresh answer from $reference with ".(scalar(keys %$items))." number of items");
		$refreshCustomItems->{$reference} = $items;
	}
	delete $provider->{refreshing};
	delete $provider->{refreshStarted};
	$provider->{refreshed} = 1;

	my $lastProvider = 1;
	for my $id (keys %$customItemProviders) {
		if(defined($customItemProviders->{$id}->{refreshing}) && !$customItemProviders->{$id}->{refreshed}) {
			$lastProvider = 0;
		}
	}
	if($lastProvider) {
		$log->info("This was the last one, finishing...");
		my @providers = ();
		for my $key (keys %$refreshCustomItems) {
			$customItems->{$key} = $refreshCustomItems->{$key};
			push @providers,$key;
		}
		$refreshCustomItems = undef;
		Slim::Control::Request::notifyFromArray(undef,['customclockchangedcustomitems',\@providers]);
		$log->debug("Scheduling next refresh...");
		my $interval = _getValidatedInterval('customitemsrefreshinterval', 300, 5);
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + ($interval), \&refreshCustomItems);
	}else {
		$log->debug("Scheduling refresh of next provider");
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.1, \&refreshNextProvider);	
	}
}

sub refreshNextProvider {
	Slim::Utils::Timers::killTimers(undef, \&refreshNextProvider); #Paranoia check
	for my $id (keys %$customItemProviders) {
		if(defined($customItemProviders->{$id}->{refreshing}) && !$customItemProviders->{$id}->{refreshed} && !$customItemProviders->{$id}->{refreshStarted}) {
			$customItemProviders->{$id}->{refreshStarted} = 1;
			$log->info("Start refreshing $id");
			my $providerId = $id;
			my $generation = $customItemProviders->{$providerId}->{refreshGeneration};
			my $completion = sub {
				my ($reference, $items) = @_;
				addingCustomItems($providerId, $items, $generation);
			};
			my $timeoutCallback = sub {
				return if !defined($customItemProviders->{$providerId}) || !$customItemProviders->{$providerId}->{refreshing};
				$customItemProviders->{$providerId}->{refreshError} = 1;
				$log->error("Timed out refreshing $providerId");
				my %empty = ();
				addingCustomItems($providerId, \%empty, $generation);
			};
			$customItemProviders->{$providerId}->{refreshTimeoutCallback} = $timeoutCallback;
			Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + $customItemRefreshTimeout, $timeoutCallback);
			eval { 
				&{$customItemProviders->{$id}->{callback}}($id,$completion); 
			};
			if( $@ ) {
				$customItemProviders->{$id}->{refreshError} = 1;
	    		$log->error("Error refreshing $id: $@");
	    		my %empty = ();
		    	addingCustomItems($id,\%empty,$generation);
			}
			last;
		}
	}
}

sub refreshCustomItemsCommand {
	my $request = shift;
	my $provider = $request->getParam('provider');
	refreshCustomItems($provider);
	$request->setStatusDone();
}

sub refreshCustomItems {
	my $provider = shift;
	$log->debug("Refreshing custom items: ".($provider?$provider:""));
	Slim::Utils::Timers::killTimers(undef, \&refreshCustomItems); #Paranoia check
	if(defined($provider) && $provider ne "" && !defined($customItemProviders->{$provider})) {
		$log->warn("Unknown custom item provider: $provider");
		my $interval = _getValidatedInterval('customitemsrefreshinterval', 300, 5);
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + ($interval), \&refreshCustomItems);
		return;
	}
	if(scalar(keys %$customItemProviders)>0 && (!defined($provider) || $provider eq "" || defined($customItemProviders->{$provider}))) {
		$log->debug("Preparing for refresh");
		if(!defined($refreshCustomItems)) {
			$refreshGeneration++;
		}
		for my $id (keys %$customItemProviders) {
			if((!defined($customItemProviders->{$id}->{refreshing}) || !$customItemProviders->{$id}->{refreshing}) && 
				(!defined($provider) || $provider eq "" || $provider eq $id)) {
					
				$log->debug("Mark $id for refresh");

				$customItemProviders->{$id}->{refreshing} = 1;
				$customItemProviders->{$id}->{refreshed} = 0;
				$customItemProviders->{$id}->{refreshGeneration} = $refreshGeneration;
				delete $customItemProviders->{$id}->{refreshStarted};
				delete $customItemProviders->{$id}->{refreshError};	
			}
		}	
		if(!defined($refreshCustomItems)) {
			$refreshCustomItems = {};
			$log->debug("Scheduling refresh of next provider");
			Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 0.1, \&refreshNextProvider);	
		}else {
			$log->info("Refresh already in progress, no need to schedule any provider for refresh");
		}
	}elsif(!defined($provider) || $provider eq "") {
		$log->debug("Nothing to refresh, scheduling next refresh...");
		my $interval = _getValidatedInterval('customitemsrefreshinterval', 300, 5);
		Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + ($interval), \&refreshCustomItems);
	}
}

sub changedRating {
	my $request = shift;

	my $client = $request->client();
	my $trackId = $request->getParam('_trackid');
	my $track = Slim::Schema->resultset('Track')->find($trackId);
	updateTitleFormats($client,$track);
}

sub changedSong {
	my $request = shift;

	my $client = $request->client();

	if($request->isCommand([['playlist'],['newsong']])) {
		$log->debug("Got playlist newsong");

	}else {
		$log->debug("Got ".$request->getRequestString());
	}
	my $songIndex = Slim::Player::Source::playingSongIndex($client);
	my $song = Slim::Player::Playlist::song($client,$songIndex);

	updateTitleFormats($client,$song);
}

sub updateTitleFormats {
	my $client = shift;
	my $song = shift;

	my $titleFormatsHash = {};
	my $formats = $prefs->get("titleformats");
	$formats = [] if ref($formats) ne 'ARRAY';
	for my $format (@$formats) {
		my $value = undef;
		if(defined($song)) {
			$value = Slim::Music::Info::displayText($client,$song,$format);
		}
		if(defined($value) && $value ne "") {
			$titleFormatsHash->{$format} = $value;
		}else {
			$titleFormatsHash->{$format} = "";
		}
	}
	my $url = "";
	if(defined($song) && $song->can('url')) {
		$url = $song->url;
	}
	# Notify on both transitions (song present and song absent) so the
	# applet can tell a genuinely-empty update from "nothing changed" and
	# clear its cached title formats when the playlist stops/clears.
	Slim::Control::Request::notifyFromArray(undef,['customclocktitleformatsupdated', $titleFormatsHash, $url]);
}

sub webPages {
	my %pages = (
		"CustomClockHelper/export\.(?:htm|xml|binfile)" => \&exportJSON,
	);
	for my $page (keys %pages) {
		if(UNIVERSAL::can("Slim::Web::Pages","addPageFunction")) {
			Slim::Web::Pages->addPageFunction($page, $pages{$page});
		}else {
			Slim::Web::HTTP::addPageFunction($page, $pages{$page});
		}
	}
}

sub exportJSON {
	my ($client, $params, $prepareResponseForSending, $httpClient, $response) = @_;
	my $style = Plugins::CustomClockHelper::Plugin->getStyle($params->{'style'});
	if(!defined($style)) {
		$log->warn("Unable to export missing style: ".($params->{'style'} || ''));
		$response->header("Content-Type","text/plain; charset=utf-8");
		my $message = "Requested style was not found.";
		return \$message;
	}
	my $filename = $params->{'style'};
	$filename =~ s/[^A-Za-z0-9._-]/_/g;
	$filename = 'style' if $filename eq '';
	$response->header("Content-Disposition","attachment; filename=\"".$filename.".txt\"");
	my $message = JSON::XS::encode_json($style);
	return \$message;
}

sub getStyleKey {
	my $style = shift;

	return undef if ref($style) ne 'HASH';
	my $models = $style->{'models'};
	return undef if ref($models) ne 'ARRAY' || ref($style->{'items'}) ne 'ARRAY' || !defined($style->{'name'}) || $style->{'name'} eq '';
	my @sortedModels = sort { $a cmp $b } @$models;
	# No models means "not restricted to specific devices" - matches the
	# pre-existing convention (ImportStyle.pm/StyleSettings.pm both only
	# appended " - <models>" when there was at least one model), so keep
	# a bare name here too rather than a trailing " - " with nothing after.
	return @sortedModels ? $style->{'name'}." - ".join(',',@sortedModels) : $style->{'name'};
}

# One-time startup migration: older saves (or ones made before this fix)
# may be stored under a non-canonical key (ImportStyle.pm used to
# concatenate models in JSON/checkbox order instead of getStyleKey()'s
# alphabetical order). A mismatched key breaks StyleSettings.pm's next
# lookup ("Unable to update missing or invalid style"), since it looks
# a style up by its current getStyleKey() value. Renames any local style
# whose stored key doesn't match getStyleKey(style) to the canonical key.
sub _migrateLocalStyleKeysToCanonical {
	my $localStyles = $prefs->get("styles");
	return if !$localStyles || ref($localStyles) ne 'HASH';

	my $newStyles = {};
	my $changed = 0;
	for my $key (sort keys %$localStyles) {
		my $style = $localStyles->{$key};
		my $canonicalKey = getStyleKey($style);
		if(!defined($canonicalKey) || $canonicalKey eq $key) {
			$newStyles->{$key} = $style;
			next;
		}
		if(exists $newStyles->{$canonicalKey}) {
			$log->error("Style key migration: '$key' and an existing entry both map to canonical key '$canonicalKey' - keeping the existing one, dropping '$key'");
			$changed = 1;
			next;
		}
		$log->info("Migrating local style key '$key' to canonical form '$canonicalKey'");
		$newStyles->{$canonicalKey} = $style;
		$changed = 1;
	}
	$prefs->set("styles", $newStyles) if $changed;
}

sub getStyles {
	my $localOnly = shift;

	$log->debug("Getting downloaded styles");

	my $styles = {};
	# Keys of styles sourced from local prefs -- unlike the online fetch,
	# this enumeration never fails, so it's always complete/authoritative.
	my $localKeys = {};
	# True unless an online fetch was attempted and failed -- lets callers
	# that build deletion-reconciliation notifications know whether this
	# snapshot is actually authoritative for online styles.
	my $onlineOk = 1;
	if(!$localOnly) {
		$onlineOk = 0;
		# Short explicit timeout: this runs inline in the request-handling
		# path, and LWP's default (180s) would let a slow/unreachable
		# remote catalog server stall LMS web/CLI requests.
		my $http = LWP::UserAgent->new(timeout => 5);
		my $response = $http->get("http://lms.hashsum.org/clockstyles8.json");
		if($response->is_success) {
			my $jsonStyles = $response->content;
			eval {
				my $decodedStyles = JSON::XS::decode_json($jsonStyles);
				if(ref($decodedStyles) eq 'HASH' && ref($decodedStyles->{'data'}) eq 'HASH' && ref($decodedStyles->{'data'}->{'item_loop'}) eq 'ARRAY') {
					my $stylesArray = $decodedStyles->{'data'}->{'item_loop'};
					my $allValid = 1;
					for my $item (@$stylesArray) {
						my $key = getStyleKey($item);
						if(defined($key)) {
							$styles->{$key} = $item;
						}else {
							$log->warn("Ignoring invalid online style");
							$allValid = 0;
						}
					}
					if($allValid) {
						$log->debug("Got online styles");
						$onlineOk = 1;
					}else {
						$log->error("Online style catalog contained invalid entries; treating snapshot as non-authoritative for deletions");
					}
				}else {
					$log->error("Online style catalog has an unexpected structure; treating snapshot as non-authoritative for deletions");
				}
			};
			if ($@) {
				$log->error("Failed parse online styles:\n$@\n");
			}
		}else {
			$log->error("Unable to get online styles");
		}
	}
	my $localStyles = $prefs->get("styles");
	if(ref($localStyles) eq 'HASH') {
		$log->debug("Got locally saved styles");
		for my $key (keys %$localStyles) {
			my $style = $localStyles->{$key};
			# Validate at this single central merge point (same validator
			# already used for online styles below) rather than relying on
			# every downstream consumer (StyleSettings::pages(), _withStyleId's
			# hash-spread, the applet) to defensively guard against a very
			# old/manually-corrupted local style that isn't even a HASH.
			if(!defined(getStyleKey($style))) {
				$log->error("Ignoring invalid local style '$key' - not a well-formed style");
				next;
			}
			$styles->{$key} = $style;
			$localKeys->{$key} = 1;
		}
	}elsif(defined($localStyles)) {
		$log->error("Ignoring corrupt 'styles' preference - expected a HASH, got: ".(ref($localStyles) || 'a plain scalar'));
	}
	$log->debug("GOT: ".Dumper($styles));
	return wantarray ? ($styles, $onlineOk, $localKeys) : $styles;
}

# Annotates a style hash with its stable identity (name + sorted models,
# same format as getStyleKey()) so JiveLite can distinguish style variants
# that share a display name but support different models, instead of
# reconciling by name alone. `source` tells the applet whether this entry
# is always fully enumerated (local, unaffected by online-fetch failures)
# or only conditionally so (online), so it can still reconcile a deleted/
# renamed LOCAL style even when the online catalog snapshot is incomplete.
sub _withStyleId {
	my ($key, $style, $isLocal) = @_;
	return { %$style, styleid => $key, source => ($isLocal ? 'local' : 'online') };
}

sub getStyle {
	my $self = shift;
	my $style = shift;

	my $styles = getStyles();
	if(defined($styles->{$style})) {
		return $styles->{$style};
	}
	return undef;
}

sub setStyle {
	my $self = shift;
	my $client = shift;
	my $styleId = shift;
	my $styleData = shift;

	my $styles = getStyles(1);
	if(defined($styleData)) {
		$styles->{$styleId} = $styleData;
	}else {
		delete $styles->{$styleId};
	}
	$prefs->set("styles",$styles);

	# Notify with the merged (online + local) catalog. The local-only set
	# above is only for persisting the edit -- using it here too would make
	# every local edit look like every online style was deleted, since
	# online styles never appear in the local-only set.
	my ($notifyStyles, $onlineOk, $localKeys) = getStyles();
	my @stylesArray = ();
	for my $style (keys %$notifyStyles) {
		push @stylesArray,_withStyleId($style,$notifyStyles->{$style},exists($localKeys->{$style}))
	}
	# The 3rd element tells the applet whether this snapshot is authoritative
	# for online styles (i.e. safe to use for deletion reconciliation) -- a
	# failed remote fetch must not look like "every online style is gone".
	Slim::Control::Request::notifyFromArray(undef,['customclockchangedstyles',\@stylesArray,$onlineOk?1:0]);
}

sub renameAndSetStyle {
	my $self = shift;
	my $client = shift;
	my $styleId = shift;
	my $newStyleId = shift;
	my $styleData = shift;

	my $styles = getStyles(1);
	delete $styles->{$styleId};
	$styles->{$newStyleId} = $styleData;
	$prefs->set("styles",$styles);

	# See setStyle() above: notify with the merged (online + local) catalog,
	# not the local-only set used to persist the rename.
	my ($notifyStyles, $onlineOk, $localKeys) = getStyles();
	my @stylesArray = ();
	for my $style (keys %$notifyStyles) {
		push @stylesArray,_withStyleId($style,$notifyStyles->{$style},exists($localKeys->{$style}))
	}
	Slim::Control::Request::notifyFromArray(undef,['customclockchangedstyles',\@stylesArray,$onlineOk?1:0]);
}

sub getClockStyles {
	my $request = shift;

	my ($styles, $onlineOk, $localKeys) = getStyles();

	my @stylesArray = ();
	for my $style (keys %$styles) {
		push @stylesArray,_withStyleId($style,$styles->{$style},exists($localKeys->{$style}))
	}
	$request->addResult('item_loop', \@stylesArray);
	$request->setStatusDone();
}

sub getCustomItems {
	my $request = shift;

	my $category = $request->getParam('category');
	my $result = {};
	if(defined($category)) {
		$result->{$category} = $customItems->{$category}
	}else {
		$result = $customItems;
	}
	$request->addResult('items', $result);
	$request->setStatusDone();
}

sub getTitleFormats {
	my $request = shift;

	my $client = $request->client();

	my $titleFormatsHash = {};
	my $formats = $prefs->get("titleformats");
	$formats = [] if ref($formats) ne 'ARRAY';
	my $songIndex = Slim::Player::Source::playingSongIndex($client);
	my $song = Slim::Player::Playlist::song($client,$songIndex);
	for my $format (@$formats) {
		my $value = undef;
		if(defined($song)) {
			$value = Slim::Music::Info::displayText($client,$song,$format);
		}
		if(defined($value) && $value ne "") {
			$titleFormatsHash->{$format} = $value;
		}else {
			$titleFormatsHash->{$format} = "";
		}
	}

	$request->addResult('titleformats', $titleFormatsHash);
	$request->setStatusDone();
}

sub isPluginsInstalled {
	my $client = shift;
	my $pluginList = shift;
	my $enabledPlugin = 1;
	foreach my $plugin (split /,/, $pluginList) {
		if($enabledPlugin) {
			$enabledPlugin = grep(/$plugin/, Slim::Utils::PluginManager->enabledPlugins($client));
		}
	}
	return $enabledPlugin;
}

*escape   = \&URI::Escape::uri_escape_utf8;

1;

__END__
