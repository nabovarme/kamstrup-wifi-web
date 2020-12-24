#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use Sys::Syslog;
use Redis;
use DBI;
use Crypt::Mode::CBC;
use Digest::SHA qw( sha256 hmac_sha256 );
use Config::Simple;

use lib qw( /etc/apache2/perl );
use lib qw( /opt/local/apache2/perl/ );

use Nabovarme::Db;
use Nabovarme::Crypto;

use constant CONFIG_FILE => qw (/etc/Nabovarme.conf );

my $config = new Config::Simple(CONFIG_FILE) || die $!;

openlog($0, "ndelay,pid", "local0");
syslog('info', "starting...");

my $unix_time;
my $meter_serial;
my $flash_error;
my $reset_reason;

#my $mqtt = Net::MQTT::Simple->new($config->param('mqtt_host'));

my $redis_host = $config->param('redis_host') || '127.0.0.1';
my $redis_port = $config->param('redis_port') || '6379';
my $redis = Redis->new(
	server => "$redis_host:$redis_port",
);

my $queue_name	= 'mqtt';
my $timeout		= 86400;

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

my $crypto = new Nabovarme::Crypto;

# start mqtt run loop
while (1) {
	my ($queue, $job_id) = $redis->blpop(join(':', $queue_name, 'queue'), $timeout);
	if ($job_id) {
	
		my %data = $redis->hgetall($job_id);
	
		if ($data{topic} =~ /offline\/v1\//) {
			mqtt_offline_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /flash_error\/v2/) {
			mqtt_flash_error_handler($data{topic}, $data{message});
		}
		elsif ($data{topic} =~ /reset_reason\/v2/) {
			mqtt_reset_reason_handler($data{topic}, $data{message});
		}
		
		# remove data for job
		$redis->del($job_id);
	}
}

# end of main


sub mqtt_offline_handler {
	my ($topic, $message) = @_;

	unless ($topic =~ m!/offline/v\d+/([^/]+)!) {
	        return;
	}
	$meter_serial = $1;
	$unix_time = time();

	my $quoted_meter_serial = $dbh->quote($meter_serial);
	my $quoted_unix_time = $dbh->quote($unix_time);
	$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `unix_time`) VALUES ($quoted_meter_serial, 'offline', $quoted_unix_time)]) or warn $!;
	syslog('info', $topic . "\t" . 'offline');
}

sub mqtt_flash_error_handler {
	my ($topic, $message) = @_;
	
	unless ($topic =~ m!/flash_error/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	$flash_error = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($flash_error) {
		# remove trailing nulls
		$flash_error =~ s/[\x00\s]+$//;
		$flash_error .= '';

		my $quoted_flash_error = $dbh->quote($flash_error);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
			$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES ($quoted_meter_serial, 'flash_error', $quoted_flash_error, $quoted_unix_time)]) or warn $!;
		syslog('info', $topic . "\t" . 'flash_error');
		
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

sub mqtt_reset_reason_handler {
	my ($topic, $message) = @_;
	
	unless ($topic =~ m!/reset_reason/v\d+/([^/]+)/(\d+)!) {
		return;
	}
	$meter_serial = $1;
	$unix_time = $2;

	$message =~ /(.{32})(.{16})(.+)/s;
	$reset_reason = $crypto->decrypt_topic_message_for_serial($topic, $message, $meter_serial);
	if ($reset_reason) {
		# remove trailing nulls
		$reset_reason =~ s/[\x00\s]+$//;
		$reset_reason .= '';

		my $quoted_reset_reason = $dbh->quote($reset_reason);
		my $quoted_meter_serial = $dbh->quote($meter_serial);
		my $quoted_unix_time = $dbh->quote($unix_time);
		$dbh->do(qq[INSERT INTO `log` (`serial`, `function`, `param`, `unix_time`) VALUES ($quoted_meter_serial, 'reset_reason', $quoted_reset_reason, $quoted_unix_time)]) or warn $!;
		syslog('info', $topic . "\t" . 'reset_reason');			
	}
	else {
		# hmac sha256 not ok
		syslog('info', $topic . "hmac error");
		syslog('info', $topic . "\t" . unpack('H*', $message));
	}
}

__END__
