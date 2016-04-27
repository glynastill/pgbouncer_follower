#PgBouncer Slony-I replication set & WAL replication follower

This script is a command-line utility to monitor the nodes in a Slony-I cluster 
and reconfigure pgbouncer to follow an origin or subscriber of replication sets.
Additionally the script can be used to follow WAL streaming primary/secondary
databases.

The idea is pretty simple; periodically poll the slony schema to identify origin 
and subscriber nodes and repoint an existing pgbouncer instance to follow either 
the origin for read-write or a subscriber for read-only operation. For binary WAL
replication we instead periodically poll pg_*() functions on all servers to get a
picture of replication status (pg_is_in_recovery(),pg_last_xlog_receive_location(),
pg_current_xlog_location() and pg_last_xact_replay_timestamp()).

Side note:
>Support for binary/WAL replication is an afterthought, so binary replicas are 
>considered followers of the primary if they're on the same timeline. In future
>it should be possible to improve this for replicas using replication slots 
>and pull all information required from the primary by looking at pg_replication_slots/
>pg_stat_replication.  It would also hopefully be possible to support following 
>logical replication origins similar to how we follow slony origins.
 
The script takes a template pgbouncer.ini file containing all the desired settings except 
for the target database and will write a copy with the target database and reload 
pgbouncer.  In 'ro' mode for slony replicas (not WAL replicas currently) the script 
will try and choose a subscriber node closest to pgbouncer host if IPv4 addressing 
has been used for the slony conninfos.

##Example usage

The script can be either run on a schedule or as a daemon with the "D" flag:

```bash
$ pgbouncer_follower.pl -f <config file> [-D]
```

To run as a daemon in debian:

```bash
$ sudo cp init.debian /etc/init.d/pgbouncer_follower_rw
$ cp pgbouncer_follower.pl /var/slony/pgbouncer_follower/pgbouncer_follower.pl 
$ cp pgbouncer_follower_rw.conf /var/slony/pgbouncer_follower/pgbouncer_follower_rw.conf 
$ sudo chmod +x /etc/init.d/pgbouncer_follower_rw
$ sudo update-rc.d pgbouncer_follower_rw start 99 2 3 4 5 . stop 24 0 1 6
$ sudo invoke-rc.d pgbouncer_follower_rw start
```

##Configuration options

| Section     | Parameter              | Type    | Default                                     | Comment
|:------------|:-----------------------|:--------|:--------------------------------------------|:-----------------------------------
| Replication | replication_user       | text    | *'slony'*                                   | Username used to connect to PostgreSQL and select from slony schema tables
| Replication | replication_pass       | text    | *''*                                        | Recommended to leave blank and use .pgpass file
| Replication | replication_method     | text    | *'slony'*                                   | Specifies replication method in use, possible values 'slony' or 'wal'
| Slony       | slony_cluster_name     | text    | *'replication'*                             | Name of slony cluster (without leading underscore of schema name)
| Server      | server_conninfo        | text    | *null*                                      | Conninfo string for server, can be specified multiple times.  For slony only one conninfo is required (but all nodes recommended), for WAL replication all servers required
| pgBouncer   | debug                  | boolean | *false*                                     | Churn out debugging info to log file / stdout
| pgBouncer   | follower_poll_interval | integer | *1000*                                      | Interval to poll slony cluster state when in daemon mode
| pgBouncer   | sets_to_follow         | text    | *1*                                         | Comma separated list of sets to follow or 'all' to follow all sets
| pgBouncer   | pool_mode              | 'ro/rw' | *'rw'*                                      | Select a read-only subscriber or the origin for read-write
| pgBouncer   | pool_all_databases     | boolean | *'false'*                                   | If true uses wildcard for database name in pgbouncer.ini, false uses slony database
| pgBouncer   | auth_user              | text    | *''*                                        | If set auth_user will be appended to conninfo written in [databases] section
| pgBouncer   | only_follow_origins    | boolean | *'false'*                                   | If true pgbouncer will only be reconfigured and reloaded when sets move origin
| pgBouncer   | status_file            | text    | *'/tmp/pgbouncer_follower_%mode.status'*    | File used to store a hash depicting the state of the cluster
| pgBouncer   | log_file               | text    | *'/tmp/pgbouncer_follower_%mode.log'*       | Log file for the script
| pgBouncer   | pid_file               | text    | *'/tmp/pgbouncer_follower_%mode.log'*       | PID file for the script when run as a daemon
| pgBouncer   | pool_conf_template     | text    | *'/etc/pgbouncer/pgbouncer_%mode.template'* | Template pgbouncer.ini file with your settings and a blank [databases] section
| pgBouncer   | pool_conf_target       | text    | *'/etc/pgbouncer/pgbouncer_%mode.ini'*      | Target pgbouncer.ini file to write a copy of pool_conf_template with a [databases] section to
| pgBouncer   | pool_reload_command    | text    | *'/etc/init.d/pgbouncer_%mode reload"'*     | System command to execute to reload pgbouncer instance
| pgBouncer   | max_ro_lag             | integer | *0*                                         | Maximum lag in seconds allowed for subscriber nodes when running in ro mode. 0 = don't monitor lag.

The status_file, log_file, pid_file, pool_conf_template, pool_conf_target and 
pool_reload_command parameters can contain the following special values:

    %mode - Pool Mode
    %clname - Slony cluster name
