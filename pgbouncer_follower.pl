#!/usr/bin/perl

# Script:   pgbouncer_follower.pl
# Copyright:    22/04/2012: v1.0.1 Glyn Astill <glyn@8kb.co.uk>
# Requires: Perl 5.10.1+, PostgreSQL 9.0+ Slony-I 2.0+ OR Streaming Replication
#
# This script is a command-line utility to monitor Slony-I clusters
# and reconfigure pgbouncer to follow replication sets.
#
# This script is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This script is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this script.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;
use experimental 'smartmatch';
use DBI;
use v5.10.1;
use Getopt::Long qw/GetOptions/;
use Digest::MD5 qw/md5 md5_hex md5_base64/;
use Sys::Hostname;
use IO::Socket;
use Time::HiRes qw/usleep/;
use sigtrap 'handler' => \&cleanExit, 'HUP', 'INT','ABRT','QUIT','TERM';
Getopt::Long::Configure qw/no_ignore_case/;

use vars qw{%opt};

use constant false => 0;
use constant true  => 1;

my $g_usage = 'Pass configuration file: pool_follower.pl -f <configuration_path> [-D]  ';
my $g_method = "slony";
my $g_debug = false;
my $g_pidfile = "/tmp/pgbouncer_follower_%mode.pid";
my $g_logfile = "/tmp/pgbouncer_follower_%mode.log";
my $g_poll_interval = 1000;
my $g_user = "slony";
my $g_pass;
my $g_clname = "replication";
my $g_clsets = "1";
my @g_conninfos;
my @g_cluster;                  # no_id, no_comment, no_prov, orig_sets, conninfo, dbname, host, port
my $g_status_file = "/tmp/pgbouncer_follower_%mode.status";
my $g_conf_template = "/etc/pgbouncer/pgbouncer_%mode.template";
my $g_conf_target = "/etc/pgbouncer/pgbouncer_%mode.ini";
my $g_reload_command = "/etc/init.d/pgbouncer_%mode reload";
my $g_mode = 'rw';
my $g_all_databases=false;
my $g_auth_user='';
my ($year, $month, $day, $hour, $min, $sec);
my $change_time;
my $g_host = hostname;
my ($g_addr)=inet_ntoa((gethostbyname(hostname))[4]);
my $g_origins_only = false;
my $g_best_config = false;
my $g_max_lag = 0;

die $g_usage unless GetOptions(\%opt, 'config_file|f=s', 'daemon|D',) and keys %opt and ! @ARGV;

unless (getConfig($opt{config_file})){
    print ("There was a problem reading the configuration.\n");
}
 
if ($g_debug) {
    printLogLn($g_logfile, "DEBUG: Logging to my '$g_logfile'");
    if ($g_method eq 'slony') {
        printLogLn($g_logfile, "\t Watching sets $g_clsets in Slony-I cluster '$g_clname' polling every ${g_poll_interval}ms"); 
        printLogLn($g_logfile, "\t Following " . ($g_all_databases ? "all databases" : "replicated database only") . " on an '$g_mode' node for the above replicated sets");
    }
    elsif ($g_method eq 'wal')  {
        printLogLn($g_logfile, "\t Watching streaming replication lag polling every ${g_poll_interval}ms"); 
    }
    else {
        printLogLn($g_logfile, "\t ERROR: Unknown replication method: '$g_method'"); 
	exit(1);
    }
    printLogLn($g_logfile, "\t Template config '$g_conf_template' Target config '$g_conf_target'");
    printLogLn($g_logfile, "\t Reload command is '$g_reload_command'");
    printLogLn($g_logfile, "\t Status stored in '$g_status_file'");
    printLogLn($g_logfile, "\t Using local address for '$g_host' as '$g_addr'");
    if (($g_max_lag > 0) && ($g_mode = 'ro')) {
        printLogLn($g_logfile, "\t Max lag for read only targets will be $g_max_lag seconds");
    }
    #printLogLn($g_logfile, "\t '$g_user' as '$g_pass'");
}

if (defined($opt{daemon})) {
    printLogLn($g_logfile, "pgbouncer_follower starting up");   
    if (writePID($g_pidfile)) {
        while (true) {
            doAll();
            if ($g_debug) {
                printLogLn($g_logfile, "DEBUG: Sleeping for ${g_poll_interval}ms");
            }
            usleep($g_poll_interval * 1000);
        }
    }
}
else {
    doAll();
}

cleanExit(0);

sub cleanExit {
    if (defined($opt{daemon})) {
        printLogLn($g_logfile, "pgbouncer_follower shutting down");    
        removePID($g_pidfile);
    }
    exit(0);
}

sub doAll {
    my $node_to;
    my $conninfo_read = 0;

    foreach my $conninfo (@g_conninfos) {
        $conninfo_read++;
        eval {
            if ($g_method eq 'slony') {
                @g_cluster = loadCluster($g_clname, $conninfo, $g_user, $g_pass, $g_addr, $g_clsets);
            }
            elsif ($g_method eq 'wal') {
                @g_cluster = loadBinCluster($g_user, $g_pass);
            }
            if ($g_debug) {
                printLogLn($g_logfile, "DEBUG: ($conninfo_read) " . (($g_method eq 'slony')?'Slony':'Streaming replication') . " cluster with " . scalar(@g_cluster) . " nodes " . (($g_method eq 'slony')?"read from conninfo: $conninfo":"provided via config conninfos"));
                foreach (@g_cluster) {
                    printLogLn($g_logfile, "DEBUG: Node #" . @$_[0] . " DETAIL: " . @$_[1] . " " . @$_[2] . " " . (@$_[3] // "<NONE>") . " " . @$_[4] . " " . (@$_[5] // "<NONE>") . " " . @$_[6] . " " . @$_[7] . " " . @$_[8] . " " . @$_[9] . " " . @$_[10] . " "  . @$_[11]);
                }
            }
        };
        if ($@) {
            printLogLn($g_logfile, "ERROR: Failed using conninfo: $conninfo DETAIL: $@");
        }
        elsif($g_best_config) {
            if ($g_debug) {
                if ($g_method eq 'slony') {
                    printLogLn($g_logfile, "DEBUG: Found current origin to read config from");
                }
                elsif ($g_method eq 'wal') {
                    printLogLn($g_logfile, "DEBUG: Read config from all contactable nodes");
                }
            }
            last;
        } 
    }
    unless (checkCluster($g_status_file)) {
        if ($g_debug) {
             printLogLn ($g_logfile, "DEBUG: Cluster status unchanged");
        }
    }
    else {
        printLogLn ($g_logfile, "Cluster status changed");
        $node_to = generateConfig($g_conf_template, $g_conf_target, $g_mode, $g_all_databases, $g_clsets);
        if (reloadConfig($g_reload_command)) {
            printLogLn ($g_logfile, "Pool repointed to node #$node_to");
        }
    }
}

sub reloadConfig {
    my $reload_command = shift;
    my $success = true;
    if(length($reload_command // '')) {
        printLogLn($g_logfile, "Running '$reload_command'");
        eval {
            open(RELOAD, "-|", $reload_command . " 2>&1");
            while (<RELOAD>) {
                printLogLn($g_logfile, $_);
            }
            close(RELOAD);
            printLogLn($g_logfile, "Reload command has been run.");
        };
        if ($@) {
            printLogLn($g_logfile, "ERROR: Failed to run reload command DETAIL: $@");
            $success = false;
        }
    }
    return $success;
}

sub generateConfig {
    my $template = shift;
    my $target = shift;
    my $mode = shift;
    my $all_databases = shift;
    my $clsets = shift;

    my $success = false;
    my @sets_to_follow;
    my @sets_origin;
    my @sets_subscribed;
    my $target_node_id;
    my $target_db;
    my $target_host;
    my $target_sets;
    my $target_port = 5432;
    my $target_is_origin;
    my $target_auth = "";

    if ($g_debug) {
        printLogLn($g_logfile, "DEBUG: All databases = " . ($all_databases ? 'true' : 'false'));
    }

    if ($g_auth_user ne "") {
        $target_auth = " auth_user=" . $g_auth_user;
    }

    if (open(INFILE, "<", $template)) {
        if (open(OUTFILE, ">", $target)) {
            print OUTFILE "# Configuration file autogenerated at " . getRuntime() . " from $template\n";
            foreach (<INFILE>) {
               if (m/\[databases]/) {

                    # Try and choose a node; we always assign the origin initially regardless of rw/ro status
                    # when in ro mode and if we then  find a suitable subscriber we'll reassign to it.
                    foreach my $node (@g_cluster) {
                       

                        # If the node is lagging anyway skip it 
                        if (($g_mode eq 'ro') && ($g_max_lag > 0) && ($node->[11])) {
                            printLogLn ($g_logfile, "Lag on node $node->[0] exceeds $g_max_lag seconds");
                            next;
                        }

                        if ($clsets ne 'all') {
                            @sets_to_follow = split(',', $clsets);
                            if (defined($node->[3])) {
                                @sets_origin =  split(',', $node->[3]);
                            }
                            else {
                                undef @sets_origin;
                            }
                            if (defined($node->[5])) {
                                @sets_subscribed =  split(',', $node->[5]);
                            }
                            else {
                                undef @sets_subscribed;
                            }
                        }

                        if (($clsets eq 'all' && defined($node->[3])) || (@sets_to_follow && @sets_origin && checkProvidesAllSets(\@sets_to_follow, \@sets_origin))) {
                            if (defined($node->[8])) {
                                $target_db = $node->[7];
                                $target_host = $node->[8];
                                $target_node_id = $node->[0];
                                $target_sets = $node->[3];
                                $target_is_origin = true;
                            }
                            if (defined($node->[9])) {
                                $target_port = $node->[9];
                            }
                            if ($mode eq "rw") {
                                last;
                            }
                        }
                        elsif (($mode eq "ro") && (($clsets eq 'all') || (@sets_to_follow && @sets_subscribed && checkProvidesAllSets(\@sets_to_follow, \@sets_subscribed)))) {    
                            if (defined($node->[8])) {
                                $target_db = $node->[7];
                                $target_host = $node->[8];
                                $target_node_id = $node->[0];
                                $target_sets = ($node->[5] // $node->[3]);
                                $target_is_origin = false;
                            }
                            if (defined($node->[9])) {
                                $target_port = $node->[9];
                            }
                            last;
                        }
                    }
                    if (defined($target_host)) {
                        $_ = "# Configuration for " . ($target_is_origin ? "origin" : "subscriber") . " of sets $target_sets node #$target_node_id $target_host:$target_port\n" . $_;
                        if ($g_debug) {
                            printLogLn ($g_logfile, "DEBUG: Configuration for " . ($target_is_origin ? "origin" : "subscriber") . " of sets $target_sets node #$target_node_id $target_host:$target_port");
                        }
                        if ($all_databases || $target_db eq '*') {
                            $_ =~ s/(\[databases\])/$1\n\* = host=$target_host port=$target_port$target_auth/;
                        }
                        else {
                            $_ =~ s/(\[databases\])/$1\n$target_db = host=$target_host port=$target_port dbname=$target_db$target_auth/;
                        }
                    }
                    else {
                            $_ = "# Could not find any node providing sets $g_clsets in mode $mode\n";
                            printLogLn ($g_logfile, "DEBUG: Could not find any node providing sets $g_clsets in mode $mode");
                    }
                    
               } 
               print OUTFILE $_;
            }
            close (OUTFILE); 
        }
        else {
            print ("ERROR: Can't open file $target\n");
        }
        close(INFILE);
    }
    else {
        print ("ERROR: Can't open file $template\n");
    }
    return $target_node_id;
}

sub checkCluster {
    my $infile = shift;
    my $changed = false;
    my $current_state = md5_hex('INIT');
    my $previous_state;
    foreach (@g_cluster) {
        if (!$g_origins_only || defined($_->[3])) {
            $current_state = md5_hex(($current_state // "") . $_->[0] . $_->[2] . (defined($_->[3]) ? 't' : 'f') . $_->[6] . $_->[11]);
            if ($g_debug) {
                printLogLn($g_logfile, "DEBUG: Node " . $_->[0] . " detail = " . $_->[2] . (defined($_->[3]) ? 't' : 'f') . $_->[6] . $_->[11]);
            }
        }
    }
   
    if (-f $infile) {
        if (open(CLUSTERFILE, "<", $infile)) {
            $previous_state = <CLUSTERFILE>;
            close(CLUSTERFILE);
        }
        else {
            printLogLn ($g_logfile, "ERROR: Can't open file $infile for reading");
        }
    }

    unless (-f $infile && ($current_state eq $previous_state)) {
        if ($g_debug) {
                printLogLn($g_logfile, "DEBUG: Writing to status file");
        }
        if (open(CLUSTERFILE, ">", $infile)) {
            print CLUSTERFILE $current_state;
            close(CLUSTERFILE);
        }
        else {
            printLogLn ($g_logfile, "ERROR: Can't open file $infile for writing");
        }
    }

    if ((($previous_state // "") ne "") && ($current_state ne $previous_state)){
        $changed = true;
    }

    return $changed
}

sub loadCluster {
    my $clname = shift;
    my $conninfo = shift;
    my $dbuser = shift;
    my $dbpass = shift;
    my $addr = shift;
    my $clsets = shift;
    my $param_on = 1;

    my $dsn;
    my $dbh;
    my $sth;
    my $query;
    my $version;
    my $qw_clname;
    my @cluster;

    $g_best_config = false;
    $dsn = "DBI:Pg:$conninfo};";

    eval {
        $dbh = DBI->connect($dsn, $dbuser, $dbpass, {RaiseError => 1});
        $qw_clname = $dbh->quote_identifier("_" . $clname);

        $query = "SELECT $qw_clname.getModuleVersion()";
        $sth = $dbh->prepare($query);
        $sth->execute();
        ($version) = $sth->fetchrow; 
        $sth->finish;

        $query = "WITH x AS (
                SELECT a.no_id, 
                    a.no_comment, 
                    COALESCE(b.sub_provider, 0) AS no_prov, 
                    NULLIF(array_to_string(array(SELECT set_id FROM $qw_clname.sl_set WHERE set_origin = a.no_id" .
                    ($clsets ne "all" ? " AND set_id IN (" . substr('?, ' x scalar(split(',', $clsets)), 0, -2) . ")" : "") 
                    . " ORDER BY set_id), ','), '') AS origin_sets,
                    CASE " . ((substr($version,0,3) >= 2.2) ? "WHEN a.no_failed THEN 'FAILED' " : "") . "WHEN a.no_active THEN 'ACTIVE' ELSE 'INACTIVE' END AS no_status,
                    string_agg(CASE WHEN b.sub_receiver = a.no_id AND b.sub_forward AND b.sub_active" .
                    ($clsets ne "all" ? " AND b.sub_set IN (" . substr('?, ' x scalar(split(',', $clsets)), 0, -2) . ")" : "") 
                    . " THEN b.sub_set::text END, ',' ORDER BY b.sub_set) AS prov_sets,
                    COALESCE(c.pa_conninfo,(SELECT pa_conninfo FROM $qw_clname.sl_path WHERE pa_server = $qw_clname.getlocalnodeid(?) LIMIT 1)) AS no_conninfo
                FROM $qw_clname.sl_node a
                LEFT JOIN $qw_clname.sl_subscribe b ON a.no_id = b.sub_receiver AND b.sub_set <> 999 
                LEFT JOIN $qw_clname.sl_path c ON c.pa_server = a.no_id AND c.pa_client = $qw_clname.getlocalnodeid(?)
                LEFT JOIN $qw_clname.sl_set d ON d.set_origin = a.no_id
                GROUP BY b.sub_provider, a.no_id, a.no_comment, c.pa_conninfo, a.no_active
                ORDER BY (COALESCE(b.sub_provider, 0) = 0) DESC, a.no_id ASC
                ), z AS (
                SELECT x.*,  
                    CASE WHEN x.no_conninfo ilike '%dbname=%' THEN(regexp_matches(x.no_conninfo, E'dbname=(.+?)\\\\M', 'ig'))[1] END AS database,
                    CASE WHEN x.no_conninfo ilike '%host=%' THEN(regexp_matches(x.no_conninfo, E'host=(.+?)(?=\\\\s|\$)', 'ig'))[1] END AS host,
                    CASE WHEN x.no_conninfo ilike '%port=%' THEN(regexp_matches(x.no_conninfo, E'port=(.+?)\\\\M', 'ig'))[1] ELSE '5432' END AS port,
                    (no_id = $qw_clname.getlocalnodeid(?)) AS this_node,
                    COALESCE((? BETWEEN 1 AND extract(epoch from s.st_lag_time)),false) AS lag_exceeded
                FROM x 
                LEFT JOIN $qw_clname.sl_status s ON s.st_received = x.no_id
		WHERE x.no_conninfo != '<event pending>'
                )
                SELECT * FROM z 
                ORDER BY origin_sets, @(CASE WHEN (host ~ '^[0-9]{1,3}(.[0-9]{1,3}){3}\$') THEN host::inet ELSE '255.255.255.255'::inet END - ?::inet) ASC";

        if ($g_debug) { 
#            printLogLn($g_logfile, "DEBUG: " . $query);
        }

        $sth = $dbh->prepare($query);

        if ($clsets ne "all") {
            for (0..1) { 
                foreach my $param (split(",", $clsets)) {
                    $sth->bind_param($param_on, $param);
                    $param_on++;
                } 
            }
        }
        # This param is taken 3 times
        for (0..2) {
            $sth->bind_param($param_on, "_" . $clname);
            $param_on++;
        }
        $sth->bind_param($param_on, $g_max_lag);
        $param_on++;
        $sth->bind_param($param_on, (isInet($addr) ? $addr : '255.255.255.255'));
        $sth->execute();

        while (my @node = $sth->fetchrow) {
            # If some origin sets exist for this node row (we can assume they're the sets we're following since they're filtered in the query)
            # and the row is flagged as this_node then we have found the best node to read the configuration from.
            if (defined($node[3]) && $node[10]) {
                $g_best_config = true;
            }
            push(@cluster,  \@node);
        }

        $sth->finish;
        $dbh->disconnect();
    };
    if ($@) { 
        printLogLn($g_logfile, "ERROR: Failed to execute query against Postgres server: $@");
    }

    return @cluster;
}

sub loadBinCluster {
    my $dbuser = shift;
    my $dbpass = shift;

    my $dsn;
    my $dbh;
    my $sth;
    my $query;
    my $recovery;
    my $xlog_location;
    my $apply_lag;
    my $primaries = 0;

    my @parts;
    my $timeline;
    my $location;
    my $primary_location;

    my $hostname;
    my $port;
    my $database;
    my @tmp_cluster;
    my @cluster;
    my $node_id = 1;
    $g_best_config = true;

    foreach my $conninfo (@g_conninfos) {
        $dsn = "DBI:Pg:$conninfo};";

        eval {
            $dbh = DBI->connect($dsn, $dbuser, $dbpass, {RaiseError => 1});
            # Check to see if the server is a secondary, and also pull the current xlog
            # location and the apply lag using pg_last_xact_replay_timestamp to get the
            # last commit timestamp from the primary applied on the secondary.
            # We will need to compare the current receive location to the primary xlog 
            # location, if they differ we can then use the apply_lag value; we'll have 
            # to post-process this.
            # In 9.6+ we might want to pull the system identifier from pg_controldata view too
            $query = "SELECT pg_is_in_recovery(), 
                          CASE 
                              WHEN pg_is_in_recovery() THEN pg_last_xlog_receive_location() 
                              ELSE pg_current_xlog_location() 
                          END,
                          COALESCE(extract(epoch from current_timestamp-pg_last_xact_replay_timestamp()),0)";
            $sth = $dbh->prepare($query);
            $sth->execute();
            ($recovery, $xlog_location, $apply_lag) = $sth->fetchrow;
            $sth->finish;

            ($port) = $conninfo =~ m/port=(.+?)(\s|$)/g; 
            ($hostname) = $conninfo =~ m/host=(.+?)(\s|$)/g; 
            ($database) = $conninfo =~ m/dbname=(.+?)(\s|$)/g; 
            @parts = split('/', $xlog_location, 2);
            $timeline = qtrim(trim($parts[0]));
            $location = hex(qtrim(trim($parts[1])));

            if ($g_debug) {
                printLogLn($g_logfile, "DEBUG: Server: $hostname:$port " . ($recovery ? 'secondary' : 'primary') . " at $xlog_location ($timeline/$location)");
            }

            # For WAL replication we assume if we can contact a server then it is active,
            # which isn't strictly true, but nodes that have fallen behind can be excluded
            # via the max_ro_lag setting.  We also substitute timeline+1 for the slony 
            # replication set.
	    if (!$recovery) {
		$primaries++;
		$primary_location = $xlog_location;
                my @node=(1,'Primary',0,$timeline,"ACTIVE",($timeline+1),$conninfo,$database,$hostname,$port,1,$xlog_location,$apply_lag);
                push(@tmp_cluster,  \@node);
            }
	    else {
                $node_id++;	
                my @node=($node_id,"Secondary".($node_id-1),1,undef,"ACTIVE",($timeline+1),$conninfo,$database,$hostname,$port,$node_id,$xlog_location,$apply_lag);
                push(@tmp_cluster,  \@node);
            }
        };
        if ($@) {
            printLogLn($g_logfile, "ERROR: Could not connect to server with conninfo: $conninfo DETAIL: $@");
        }
    }

    # Error if more than one primary discovered.
    if ($primaries != 1) {
        printLogLn($g_logfile, "ERROR: Invalid quantity of primaries: $primaries");
        die "no primaries found";
    }
    # Do the post processing we mentioned above, once we know xlog locations differ
    # then we can say the apply lag is correct, else it's just there has been no
    # activity on the master. In the case the xlog locations differ but apply_lag 
    # is 0 then it means no WAL has been applied since srver start; we don't know
    # a time for lag in this case.
    else {
        foreach (@tmp_cluster) {
            $apply_lag = false;
            if ($g_max_lag > 0) {
                if ((@$_[11] ne $primary_location) && (@$_[12] > $g_max_lag || @$_[12] == 0)) {
                   $apply_lag  = true;
                }
            }
            my @node=(@$_[0],@$_[1],@$_[2],@$_[3],@$_[4],@$_[5],@$_[6],@$_[7],@$_[8],@$_[9],@$_[10],$apply_lag);
            push(@cluster,  \@node);
        }
    }

    return @cluster;
}

sub getConfig {
    my @fields;
    my $success = false;
    my $infile = shift;
    my $value;

    if (open(CFGFILE, "<", $infile)) {
        foreach (<CFGFILE>) {
            chomp $_;
            for ($_) {
                s/\r//;
                #s/\#.*//;
                s/#(?=(?:(?:[^']|[^"]*+'){2})*+[^']|[^"]*+\z).*//;
            } 
            if (length(trim($_))) {
                @fields = split('=', $_, 2);
                $value = qtrim(trim($fields[1]));
                given(lc($fields[0])) {
                    when(/\breplication_method\b/i) {
                        $g_method = $value;
                    }
                    when(/\bdebug\b/i) {
                        $g_debug = checkBoolean($value);
                    }
                    when(/\bpid_file\b/i) {
                        $g_pidfile = $value;
                    }
                    when(/\blog_file\b/i) {
                        $g_logfile = $value;
                    }
                    when(/\bslony_user\b/i) { # Depreciated
                        $g_user = $value;
                    }
                    when(/\bslony_pass\b/i) { # Depreciated
                        $g_pass = $value;
                    }
                    when(/\breplication_user\b/i) {
                        $g_user = $value;
                    }
                    when(/\breplication_pass\b/i) {
                        $g_pass = $value;
                    }
                    when(/\bslony_cluster_name\b/i) {
                        $g_clname = $value;
                    }
                    when(/\bslony_sets_to_follow\b/i) {
                        $g_clsets = $value;
                    }
                    when(/\bserver_conninfo\b/i) {
                        push(@g_conninfos, $value);
                    }
                    when(/\bfollower_poll_interval\b/i) {
                        $g_poll_interval = checkInteger($value);
                    }
                    when(/\bstatus_file\b/i) {
                        $g_status_file = $value;
                    } 
                    when(/\bpool_conf_template\b/i) {
                        $g_conf_template = $value;
                    } 
                    when(/\bpool_conf_target\b/i) {
                        $g_conf_target = $value;
                    } 
                    when(/\bpool_reload_command\b/i) {
                        $g_reload_command = $value;
                    } 
                    when(/\bpool_mode\b/i) {
                        $g_mode = lc($value);
                    } 
                    when(/\bpool_all_databases\b/i) {
                        $g_all_databases = checkBoolean($value);
                    }
                    when(/\bauth_user\b/i) {
                        $g_auth_user = $value;
                    }
                    when(/\bonly_follow_origins\b/i) {
                        $g_origins_only = checkBoolean($value);
                    }
                    when(/\bmax_ro_lag\b/i) {
                        $g_max_lag = checkInteger($value);
                    }
                }  
            }
        }
        close (CFGFILE);
        if (defined($g_user) && (scalar(@g_conninfos) > 0)) {
           $success = true;
        }
        # Replace %mode and %clname here for actual value
        for ($g_pidfile, $g_logfile, $g_status_file, $g_conf_template, $g_conf_target, $g_reload_command) {
            s/\%mode/$g_mode/g;
            s/\%clname/$g_clname/g;
        }


    }
    else {
        printLogLn($g_logfile, "ERROR: Could not read configuration from '$infile'");
    }
    return $success;
}

sub writePID {
    my $pidfile = shift;
    my $success = true;

    eval {
        open (PIDFILE, ">", $pidfile);
        print PIDFILE $$;
        close (PIDFILE);
        if ($g_debug) {
            printLogLn($g_logfile, "DEBUG: Created PID file '$pidfile' for process $$");
        }
    };
    if ($@) {
        printLogLn($g_logfile, "ERROR: unable to write pidfile at '$pidfile' DETAIL $!");       
        $success = false;
    }
    return $success;
}

sub removePID {
    my $pidfile = shift;
    my $success = true;

    eval {
        if (-f $pidfile) {
            unlink $pidfile;
            if ($g_debug) {
                printLogLn($g_logfile, "DEBUG: Removed PID file '$pidfile'");
            }
        }
        elsif ($g_debug){
            printLogLn($g_logfile, "DEBUG: PID file '$pidfile' never existed to be removed");
        } 
    };
    if ($@) {
        printLogLn($g_logfile, "ERROR: unable to remove pidfile at '$pidfile' DETAIL $!");       
        $success = false;
    }
    return $success
}

sub checkBoolean {
    my $text = shift;
    my $value = undef;
    if ( grep /^$text$/i, ("y","yes","t","true","on") ) {
        $value = true;
    }
    elsif ( grep /^$text$/i, ("n","no","f","false","off") ) {
        $value = false;
    }
    return $value;
}

sub checkInteger {
    my $integer = shift;
    my $value = undef;

    if (($integer * 1) eq $integer) {
        $value = int($integer);
    }
    return $value;
}

sub checkProvidesAllSets { 
    my ($originSets, $providerSets) = @_;
    my %test_hash;

    undef @test_hash{@$originSets};       # add a hash key for each element of @$originSets
    delete @test_hash{@$providerSets};    # remove all keys for elements of @$providerSets

    return !%test_hash;              # return false if any keys are left in the hash
}

sub isInet {
    my $address = shift;
    my $success = true;

    my(@octets) = $address =~ /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
    if (@octets == 4) {
        foreach (@octets) {
            unless ($_ <= 255) {
                $success = false;
            }
        }
    }
    else {
        $success = false;
    }

    return $success;
}

sub qtrim {
    my $string = shift;
    $string =~ s/^('|")+//;
    $string =~ s/('|")+$//;
    return $string;
}

sub trim {
    my $string = shift;
    $string =~ s/^\s+//;
    $string =~ s/\s+$//;
    return $string;
}

sub getRuntime {
    my ($year, $month, $day, $hour, $min, $sec) = (localtime(time))[5,4,3,2,1,0];
    my $time = sprintf ("%02d:%02d:%02d on %02d/%02d/%04d", $hour, $min, $sec, $day, $month+1, $year+1900);
    return $time;
}

sub printLog {
    my $logfile = shift;
    my $message = shift;

    print $message;

    if (open(LOGFILE, ">>", $logfile)) {
        print LOGFILE getRuntime() . " " . $message;
        close (LOGFILE);
    }
    else {
        printLn("ERROR: Unable to write to logfile $logfile");
    }
}

sub printLogLn {
    printLog ($_[0], $_[1] . $/);
}

sub printLn {
    print ((@_ ? join($/, @_) : $_), $/);
}
