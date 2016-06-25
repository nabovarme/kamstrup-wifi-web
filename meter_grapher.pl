#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Net::MQTT::Simple;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );

#use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );
use Nabovarme::Db;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $protocol_version;
my $unix_time;
my $meter_serial;
my $sw_version;
my $valve_status;
my $uptime;

#my $mqtt = Net::MQTT::Simple->new(q[127.0.0.1]);
my $mqtt = Net::MQTT::Simple->new(q[10.8.0.84]);
my $mqtt_data = undef;
#my $mqtt_count = 0;

# connect to db
my $dbh;
if ($dbh = Nabovarme::Db->my_connect) {
	$dbh->{'mysql_auto_reconnect'} = 1;
	syslog('info', "connected to db");
}
else {
	syslog('info', "cant't connect to db $!");
	die $!;
}

# start mqtt run loop
$mqtt->run(	q[/sample/v1/#] => \&mqtt_sample_handler,
	q[/version/v1/#] => \&mqtt_version_handler,
	q[/status/v1/#] => \&mqtt_status_handler,
	q[/uptime/v1/#] => \&mqtt_uptime_handler,
	
	q[/sample/v2/#] => \&v2_mqtt_sample_handler,
	q[/version/v2/#] => \&v2_mqtt_version_handler,
	q[/status/v2/#] => \&v2_mqtt_status_handler,
	q[/uptime/v2/#] => \&v2_mqtt_uptime_handler,
	q[/crypto/v2/#] => \&v2_mqtt_crypto_test_handler
);

# end of main

sub mqtt_version_handler {
	my ($topic, $message) = @_;
	unless ($topic =~ m!/version/v1/(\d+)/(\d+)!) {
		return;
	}
	$sw_version = $message;
	$meter_serial = $1;
	$unix_time = $2;
	
	my $quoted_sw_version = $dbh->quote($sw_version);
	my $quoted_meter_serial = $dbh->quote($meter_serial);
	my $quoted_unix_time = $dbh->quote($unix_time);
	$dbh->do(qq[UPDATE meters SET \
					sw_version = $quoted_sw_version, \
					last_updated = $quoted_unix_time \
					WHERE serial = $quoted_meter_serial]) or warn $!;
	warn Dumper({sw_version => $sw_version});
}

sub mqtt_status_handler {
	my ($topic, $message) = @_;
	unless ($topic =~ m!/status/v1/(\d+)/(\d+)!) {
		return;
	}
	$valve_status = $message;
	$meter_serial = $1;
	$unix_time = $2;

	my $quoted_valve_status = $dbh->quote($valve_status);
	my $quoted_meter_serial = $dbh->quote($meter_serial);
	my $quoted_unix_time = $dbh->quote($unix_time);
	$dbh->do(qq[UPDATE meters SET \
					valve_status = $quoted_valve_status, \
					last_updated = $quoted_unix_time \
					WHERE serial = $quoted_meter_serial]) or warn $!;
	warn Dumper({sw_version => $valve_status});
}

sub mqtt_uptime_handler {
	my ($topic, $message) = @_;
	unless ($topic =~ m!/uptime/v1/(\d+)/(\d+)!) {
		return;
	}
	$uptime = $message;
	$meter_serial = $1;
	$unix_time = $2;
	
	my $quoted_uptime = $dbh->quote($uptime);
	my $quoted_meter_serial = $dbh->quote($meter_serial);
	my $quoted_unix_time = $dbh->quote($unix_time);
	$dbh->do(qq[UPDATE meters SET \
					uptime = $quoted_uptime, \
					last_updated = $quoted_unix_time \
					WHERE serial = $quoted_meter_serial]) or warn $!;
	warn Dumper({sw_version => $sw_version});
}

sub mqtt_sample_handler {
	my ($topic, $message) = @_;

	unless ($topic =~ m!/sample/v\d+/(\d+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
		
	# parse message
	$message =~ s/&$//;
	
	my ($key, $value, $unit);
	my @key_value_list = split(/&/, $message);
	my $key_value; 
	foreach $key_value (@key_value_list) {
		if (($key, $value, $unit) = $key_value =~ /([^=]*)=(\S+)(?:\s+(.*))?/) {
			# check energy register unit
			if ($key =~ /^e1$/i) {
				if ($unit =~ /^MWh$/i) {
					$value *= 1000;
					$unit = 'kWh';
				}
			}
			$mqtt_data->{$key} = $value;
		}
	}
	warn Dumper($mqtt_data);
	
	# validate data
	my $data_validation_ok = undef;
	if (length($mqtt_data->{effect1}) && length($mqtt_data->{e1})) {
		$data_validation_ok = 1;
	}
	
	# save to db
	if ($data_validation_ok && ($unix_time < time() + 7200)) {
		my $sth = $dbh->prepare(qq[INSERT INTO `samples` (
			`serial`,
			`heap`,
			`flow_temp`,
			`return_flow_temp`,
			`temp_diff`,
			`flow`,
			`effect`,
			`hours`,
			`volume`,
			`energy`,
			`unix_time`
			) VALUES (] . 
			$dbh->quote($meter_serial) . ',' . 
			$dbh->quote($mqtt_data->{heap}) . ',' . 
			$dbh->quote($mqtt_data->{t1}) . ',' . 
			$dbh->quote($mqtt_data->{t2}) . ',' . 
			$dbh->quote($mqtt_data->{tdif}) . ',' . 
			$dbh->quote($mqtt_data->{flow1}) . ',' . 
			$dbh->quote($mqtt_data->{effect1}) . ',' . 
			$dbh->quote($mqtt_data->{hr}) . ',' . 
			$dbh->quote($mqtt_data->{v1}) . ',' . 
			$dbh->quote($mqtt_data->{e1}) . ',' .
			$dbh->quote($unix_time) . qq[)]);
		$sth->execute || syslog('info', "can't log to db");
		$sth->finish;
	}
	$mqtt_data = undef;
}



sub v2_mqtt_version_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/version/v\d+/(\d+)/(\d+)!) {
	        return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		warn Dumper("message: " . unpack('H*', $message));
		warn Dumper("aes key: " . unpack('H*', $aes_key));
		warn Dumper("hmac sha256 key: " . unpack('H*', $hmac_sha256_key));
		warn Dumper("iv: " . unpack('H*', $iv));
		warn Dumper("ciphertext: " . unpack('H*', $ciphertext));
		warn Dumper("mac: " . unpack('H*', $mac));
		
		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$sw_version = $m->decrypt($ciphertext, $aes_key, $iv);
			my $quoted_sw_version = $dbh->quote($sw_version);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							sw_version = $quoted_sw_version, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial]) or warn $!;
			warn Dumper({sw_version => $sw_version});
		}
		else {
			# hmac sha256 not ok
			warn Dumper("serial $meter_serial checksum error");
		}
	}
}

sub v2_mqtt_status_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/status/v\d+/(\d+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		warn Dumper("message: " . unpack('H*', $message));
		warn Dumper("aes key: " . unpack('H*', $aes_key));
		warn Dumper("hmac sha256 key: " . unpack('H*', $hmac_sha256_key));
		warn Dumper("iv: " . unpack('H*', $iv));
		warn Dumper("ciphertext: " . unpack('H*', $ciphertext));
		warn Dumper("mac: " . unpack('H*', $mac));
		
		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$valve_status = $m->decrypt($ciphertext, $aes_key, $iv);
			my $quoted_valve_status = $dbh->quote($valve_status);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							valve_status = $quoted_valve_status, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial]) or warn $!;
			warn Dumper({valve_status => $valve_status});
			
		}
		else {
			# hmac sha256 not ok
			warn Dumper("serial $meter_serial checksum error");
		}
	}
}

sub v2_mqtt_uptime_handler {
	my ($topic, $message) = @_;
	my $m;
	
	unless ($topic =~ m!/uptime/v\d+/(\d+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;
	
	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		warn Dumper("message: " . unpack('H*', $message));
		warn Dumper("aes key: " . unpack('H*', $aes_key));
		warn Dumper("hmac sha256 key: " . unpack('H*', $hmac_sha256_key));
		warn Dumper("iv: " . unpack('H*', $iv));
		warn Dumper("ciphertext: " . unpack('H*', $ciphertext));
		warn Dumper("mac: " . unpack('H*', $mac));
		
		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$uptime = $m->decrypt($ciphertext, $aes_key, $iv);
			my $quoted_uptime = $dbh->quote($uptime);
			my $quoted_meter_serial = $dbh->quote($meter_serial);
			my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[UPDATE meters SET \
							uptime = $quoted_uptime, \
							last_updated = $quoted_unix_time \
							WHERE serial = $quoted_meter_serial]) or warn $!;
			warn Dumper({uptime => $uptime});
		}
		else {
			# hmac sha256 not ok
			warn Dumper("serial $meter_serial checksum error");
		}
	}
}

sub v2_mqtt_sample_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/sample/v\d+/(\d+)/(\d+)!) {
		return;
	}
	$protocol_version = $1;
	$meter_serial = $2;
	$unix_time = $3;
	
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		warn Dumper("message: " . unpack('H*', $message));
		warn Dumper("aes key: " . unpack('H*', $aes_key));
		warn Dumper("hmac sha256 key: " . unpack('H*', $hmac_sha256_key));
		warn Dumper("iv: " . unpack('H*', $iv));
		warn Dumper("ciphertext: " . unpack('H*', $ciphertext));
		warn Dumper("mac: " . unpack('H*', $mac));
		
		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$message = $m->decrypt($ciphertext, $aes_key, $iv);
			warn Dumper $message;
			warn Dumper unpack('H*', $message);
			
			# parse message
			$message =~ s/&$//;
	
			my ($key, $value, $unit);
			my @key_value_list = split(/&/, $message);
			my $key_value; 
			foreach $key_value (@key_value_list) {
				if (($key, $value, $unit) = $key_value =~ /([^=]*)=(\S+)(?:\s+(.*))?/) {
					# check energy register unit
					if ($key =~ /^e1$/i) {
						if ($unit =~ /^MWh$/i) {
							$value *= 1000;
							$unit = 'kWh';
						}
					}
					$mqtt_data->{$key} = $value;
				}
			}
			warn Dumper($mqtt_data);
		
			# save to db
			if ($unix_time < time() + 7200) {
				my $sth = $dbh->prepare(qq[INSERT INTO `samples` (
					`serial`,
					`heap`,
					`flow_temp`,
					`return_flow_temp`,
					`temp_diff`,
					`flow`,
					`effect`,
					`hours`,
					`volume`,
					`energy`,
					`unix_time`
					) VALUES (] . 
					$dbh->quote($meter_serial) . ',' . 
					$dbh->quote($mqtt_data->{heap}) . ',' . 
					$dbh->quote($mqtt_data->{t1}) . ',' . 
					$dbh->quote($mqtt_data->{t2}) . ',' . 
					$dbh->quote($mqtt_data->{tdif}) . ',' . 
					$dbh->quote($mqtt_data->{flow1}) . ',' . 
					$dbh->quote($mqtt_data->{effect1}) . ',' . 
					$dbh->quote($mqtt_data->{hr}) . ',' . 
					$dbh->quote($mqtt_data->{v1}) . ',' . 
					$dbh->quote($mqtt_data->{e1}) . ',' .
					$dbh->quote($unix_time) . qq[)]);
				$sth->execute || syslog('info', "can't log to db");
				$sth->finish;
			}
		}
		else {
			# hmac sha256 not ok
			warn Dumper("serial $meter_serial checksum error");
		}
	}
	$mqtt_data = undef;
}


sub v2_mqtt_crypto_test_handler {
	my ($topic, $message) = @_;
	my $m;

	unless ($topic =~ m!/crypto/v\d+/(\d+)/(\d+)!) {
	        return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	my $mac = $1;
	my $iv = $2;
	my $ciphertext = $3;
		
	my $sth = $dbh->prepare(qq[SELECT `key` FROM meters WHERE serial = ] . $dbh->quote($meter_serial) . qq[ LIMIT 1]);
	$sth->execute;
	if ($sth->rows) {
		my $key = $sth->fetchrow_hashref->{key} || warn "no aes key found";
		my $sha256 = sha256(pack('H*', $key));
		my $aes_key = substr($sha256, 0, 16);
		my $hmac_sha256_key = substr($sha256, 16, 16);

		if ($mac eq hmac_sha256($topic . $iv . $ciphertext, $hmac_sha256_key)) {
			# hmac sha256 ok
			$m = Crypt::Mode::CBC->new('AES');
			$message = $m->decrypt($ciphertext, $aes_key, $iv);
			warn Dumper({	"message" => unpack('H*', $message),
							"aes key" => unpack('H*', $aes_key),
							"hmac sha256 key" => unpack('H*', $hmac_sha256_key),
							"iv" => unpack('H*', $iv),
							"ciphertext" => unpack('H*', $ciphertext),
							"mac" => unpack('H*', $mac),
							"message" => $message,
							"cleartext" => unpack('H*', $message)
						});
		}
		else {
			# hmac sha256 not ok
			warn Dumper("serial $meter_serial checksum error");
		}
	}
}

__END__
