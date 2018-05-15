#!/bin/bash

# This script is meant to check important Galera vlaues and act accordingly.
# Then, check them up again and send a mail if needed.
#
# This script is intended to be used for a 2 members cluster, it can be executed from any
MASTER1="localhost"
MASTER2="master2_ipaddress_here"
MYSQLUSER="mysql_username_here"  # Used to test cluster's status, need USAGE.
MYSQLPASS="mysql_password_here"


# Function to run at the end of the script execution, to check on the status of the cluster and send alerts if needed.
function verify_cluster {
    #Check for mysql service's status
    MASTER1DAEMSTAT=`(service mysql status | awk '{print $1}')`
    MASTER2DAEMSTAT=`(ssh root@$MASTER2 "service mysql status" | awk '{print $1}')`
    #Check for the size of the cluster
    CLUSTERSIZE=`(mysql -u $MYSQLUSER -p$MYSQLPASS -e "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'" | grep size | awk '{print $NF}')`
    #Check for the status of the cluster
    M1CLUSTERSTATUS=`(mysql -u $MYSQLUSER -p$MYSQLPASS -e "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_status'" | grep status | awk '{print $NF}')`
    M2CLUSTERSTATUS=`(ssh root@$MASTER2 "mysql -u $MYSQLUSER -p$MYSQLPASS -e \"SHOW GLOBAL STATUS LIKE 'wsrep_cluster_status'\"" | grep status | awk '{print $NF}')`

    #Process the results stored above and send log message according to result.
    if [ "$MASTER1DAEMSTAT" == "SUCCESS!" ] && [ "$MASTER2DAEMSTAT" == "SUCCESS!" ]; then
        if [ "$CLUSTERSIZE" == "2" ]; then
            if [ "$M1CLUSTERSTATUS" == "Primary" ] && [ "$M2CLUSTERSTATUS" == "Primary" ]; then
                echo -e "Daemonstatus M1: $MASTER1DAEMSTAT\nDaemonstatus M2: $MASTER2DAEMSTAT\nClusterSize: $CLUSTERSIZE\nM1 ClusterStat: $M1CLUSTERSTATUS\nM2 ClusterStat: $M2CLUSTERSTATUS\n"
                logger "GALERA OK: Cluster is started correctly."
                exit 0
            else
                echo -e "Daemonstatus M1: $MASTER1DAEMSTAT\nDaemonstatus M2: $MASTER2DAEMSTAT\nClusterSize: $CLUSTERSIZE\nM1 ClusterStat: $M1CLUSTERSTATUS\nM2 ClusterStat: $M2CLUSTERSTATUS\n"
                logger "GALERA CRITICAL: The cluster doesn't have the Primary status on one member."
                exit 0
            fi
        else
            echo -e "Daemonstatus M1: $MASTER1DAEMSTAT\nDaemonstatus M2: $MASTER2DAEMSTAT\nClusterSize: $CLUSTERSIZE\nM1 ClusterStat: $M1CLUSTERSTATUS\nM2 ClusterStat: $M2CLUSTERSTATUS\n"
            logger "GALERA CRITICAL: Cluster has only one member with both hosts started, split brain."
            exit 0
        fi
    else
        echo -e "Daemonstatus M1: $MASTER1DAEMSTAT\nDaemonstatus M2: $MASTER2DAEMSTAT\nClusterSize: $CLUSTERSIZE\nM1 ClusterStat: $M1CLUSTERSTATUS\nM2 ClusterStat: $M2CLUSTERSTATUS\n"
        logger "GALERA CRITICAL: One member's daemon is stopped."
        exit 0
    fi
}


# Check if daemon is running on any cluster member.
MASTER1DAEMSTAT=`(service mysql status | awk '{print $1}')`
MASTER2DAEMSTAT=`(ssh root@$MASTER2 "service mysql status" | awk '{print $1}')`

if [ "$MASTER1DAEMSTAT" == "SUCCESS!" ]; then

    if [ "$MASTER2DAEMSTAT" == "SUCCESS!" ]; then

        # Check for cluster size to see if both members are in quorum.

        CLUSTERSIZE=`(mysql -u $MYSQLUSER -p$MYSQLPASS -e "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_size'" | grep size | awk '{print $NF}')`
        if [ "$CLUSTERSIZE" == "1" ]; then
            #Mysql is started on both hosts but there's only one cluster member, split brain.
            ssh root@$MASTER2 "/etc/init.d/mysql stop" && /etc/init.d/mysql stop && /etc/init.d/mysql start --wsrep-new-cluster && ssh root@$MASTER2 "/etc/init.d/mysql start"
            verify_cluster
        else
            verify_cluster
        fi

    elif [ "$MASTER2DAEMSTAT" == "ERROR!" ]; then

        # Check if Master1's instance has the Primary status, this indiquate the Galera cluster is ok.

        CLUSTERSTATUS=`(mysql -u $MYSQLUSER -p$MYSQLPASS -e "SHOW GLOBAL STATUS LIKE 'wsrep_cluster_status'" | grep status | awk '{print $NF}')`
        if [ "$CLUSTERSTATUS" == "Primary" ]; then
            #Cluster is ok, Master2 is just not started.
            ssh root@$MASTER2 "/etc/init.d/mysql start"
            verify_cluster
        else
            #Cluster isn't ok, stoping and restarting.
            /etc/init.d/mysql stop && /etc/init.d/mysql start --wsrep-new-cluster && ssh root@$MASTER2 "/etc/init.d/mysql start"
            verify_cluster
        fi

    fi

elif [ "$MASTER1DAEMSTAT" == "ERROR!" ]; then

    if [ "$MASTER2DAEMSTAT" == "SUCCESS!" ]; then

        # Check if Master2's instance has the Primary status.

        CLUSTERSTATUS=`(ssh root@$MASTER2 "mysql -u $MYSQLUSER -p$MYSQLPASS -e \"SHOW GLOBAL STATUS LIKE 'wsrep_cluster_status'\"" | grep status | awk '{print $NF}')`
        if [ "$CLUSTERSTATUS" == "Primary" ]; then
            #Cluster is ok on $MASTER2, start it on $MASTER1.
            /etc/init.d/mysql start
            verify_cluster
        else
            #Cluster isn't ok on $MASTER2, restarting it correctly.
            ssh root@$MASTER2 "service mysql stop" && /etc/init.d/mysql stop && /etc/init.d/mysql start --wsrep-new-cluster && ssh root@$MASTER2 "/etc/init.d/mysql start"
            verify_cluster
        fi

    elif [ "$MASTER2DAEMSTAT" == "ERROR!" ]; then

        # Check the grastate.dat file on both host to determine who has the most up2date data and start cluster accordingly.
        MASTER1STATS=`(grep safe_to /var/lib/mysql/grastate.dat | awk '{print $NF}')`
        MASTER2STATS=`(ssh root@vl2688icingatestm2 "grep safe_to /var/lib/mysql/grastate.dat" | awk '{print $NF}')`
        if [ "$MASTER1STATS" == "1" ]; then
            /etc/init.d/mysql start --wsrep-new-cluster && ssh root@$MASTER2 "/etc/init.d/mysql start"
        elif [ "$MASTER2STATS" == "1" ]; then
            ssh root@$MASTER2 "/etc/init.d/mysql start --wsrep-new-cluster" && /etc/init.d/mysql start
        fi
        verify_cluster
    fi

fi

