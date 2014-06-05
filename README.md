#PgBouncer Slony-I replication set follower

This script is a command-line utility to monitor the nodes in a Slony-I cluster 
and reconfigure pgbouncer to follow an origin or subscriber of replication sets.

The idea is pretty simple; periodically poll the slony schema to identify origin 
and subscriber nodes and repoint an existing pgbouncer instance to follow either 
the origin for read-write or a subscriber for read-only operation.  The script 
takes a template pgbouncer.ini file containing all the desired settings except 
for the target database and will write a copy with the target database and reload 
pgbouncer.  In 'ro' mode the script will try and choose a subscriber node  closest 
to pgbouncer host if IPv4 addressing has been used for the slony conninfos.

##Example usage

The script can be either run on a schedule or as a daemon with the "D" flag:

# pgbouncer_follower.pl -f <config file> [-D]

##Configuration options

| Section   | Parameter              | Type    | Default                                     | Comment
|:----------|:-----------------------|:--------|:--------------------------------------------|:-----------------------------------
| Slony     | slony_user             | text    | *'slony'*                                   | Username used to connect to PostgreSQL and select from slony schema tables
| Slony     | slony_pass             | text    | *''*                                        | Recommended to leave blank and use .pgpass file
| Slony     | slony_cluster_name     | text    | *'replication'*                             | Name of slony cluster (without leading underscore of schema name)
| Slony     | server_conninfo        | text    | *null*                                      | Conninfo string for slony a node, can be specified multiple times
| pgBouncer | debug                  | boolean | *false*                                     | Churn out debugging info to log file / stdout
| pgBouncer | follower_poll_interval | integer | *1000*                                      | Interval to poll slony cluster state when in daemon mode
| pgBouncer | sets_to_follow         | text    | *1*                                         | Comma separated list of sets to follow or 'all' to follow all sets
| pgBouncer | pool_mode              | 'ro/rw' | *'rw'*                                      | Select a read-only subscriber or the origin for read-write
| pgBouncer | pool_all_databases     | boolean | *'false'*                                   | If true uses wildcard for database name in pgbouncer.ini, false uses slony database
| pgBouncer | status_file            | text    | *'/tmp/pgbouncer_follower_%mode.status'*    | File used to store a hash depicting the state of the cluster
| pgBouncer | log_file               | text    | *'/tmp/pgbouncer_follower_%mode.log'*       | Log file for the script
| pgBouncer | pid_file               | text    | *'/tmp/pgbouncer_follower_%mode.log'*       | PID file for the script when run as a daemon
| pgBouncer | pool_conf_template     | text    | *'/etc/pgbouncer/pgbouncer_%mode.template'* | Template pgbouncer.ini file with your settings and a blank [databases] section
| pgBouncer | pool_conf_target       | text    | *'/etc/pgbouncer/pgbouncer_%mode.ini'*      | Target pgbouncer.ini file to write a copy of pool_conf_template with a [databases] section to
| pgBouncer | pool_reload_command    | text    | *'/etc/init.d/pgbouncer_%mode reload"'*     | System command to execute to reload pgbouncer instance

The status_file, log_file, pid_file, pool_conf_template, pool_conf_target and 
pool_reload_command parameters can contain the following special values:

    %mode - Pool Mode
    %clname - Slony cluster name
