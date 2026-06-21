#!/bin/bash
# ==============================================================================
# IBM TRIRIGA DB2 Unified Provisioning Script (Executed via TRIRIGA Context)
# Modified for Custom Path Architecture: /mnt/c/Prject/DB2/home
# ==============================================================================
# This script must be initially executed as 'root'.
# ==============================================================================

# --- Configuration & Variables ---
BASE_HOME_DIR="/mnt/c/Prject/DB2/home" 
DB2_HOME="/opt/ibm/db2/V11.5" # Update this to your actual DB2 engine binaries path
DB2_PORT="50000"
DB2_DBNAME="TRIDATA"
TERRITORY="US"

# Instance Users
INST_USER="db2inst1"
FENCE_USER="db2fenc1"
DAS_USER="dasusr1"

# TRIRIGA App Users
TRIDATA_USER="tridata"
TRIRIGA_USER="tririga"

# Verify Script is executed by Root
if [ "$EUID" -ne 0 ]; then
   echo "Error: This initialization phase must be executed as root."
   exit 1
fi

echo "=================================================================="
echo "Phase 1: Provisioning Operating System Groups and Users"
echo "=================================================================="

# 1. Create Administration Groups if they don't exist
getent group db2iadm1 >/dev/null || groupadd -g 999 db2iadm1
getent group db2fadm1 >/dev/null || groupadd -g 998 db2fadm1
getent group dasadm1  >/dev/null || groupadd -g 994 dasadm1

# Ensure your custom home directory path exists
mkdir -p "$BASE_HOME_DIR"

# 2. Provision Core DB2 System Users pointed to your custom path
id -u $INST_USER >/dev/null 2>&1 || useradd -u 1004 -g db2iadm1 -m -d "$BASE_HOME_DIR/db2inst1" $INST_USER
id -u $FENCE_USER >/dev/null 2>&1 || useradd -u 1003 -g db2fadm1 -m -d "$BASE_HOME_DIR/db2fenc1" $FENCE_USER
id -u $DAS_USER   >/dev/null 2>&1 || useradd -u 1005 -g dasadm1  -m -d "$BASE_HOME_DIR/dasusr1" $DAS_USER

# 3. Provision TRIRIGA Application Access Accounts pointed to your custom path
id -u $TRIDATA_USER >/dev/null 2>&1 || useradd -u 1010  -g db2iadm1 -m -d "$BASE_HOME_DIR/tridata" $TRIDATA_USER
id -u $TRIRIGA_USER >/dev/null 2>&1 || useradd -u 10110 -g db2iadm1 -m -d "$BASE_HOME_DIR/tririga" $TRIRIGA_USER

# Set open directory permissions on your paths as per your guidelines
chmod -R 777 "$BASE_HOME_DIR/tridata"
chmod -R 777 "$BASE_HOME_DIR/tririga"

# Assign Default Temporary Passwords
echo "${TRIDATA_USER}:password" | chpasswd
echo "${TRIRIGA_USER}:password" | chpasswd

echo "System users and directory architectures initialized successfully at $BASE_HOME_DIR."

echo "=================================================================="
echo "Phase 2: Creating and Registering the DB2 Instance"
echo "=================================================================="

if [ ! -f "$DB2_HOME/instance/db2icrt" ]; then
    echo "Warning: Cannot locate db2icrt in $DB2_HOME/instance/. Continuing assuming instance exists or Docker manages it."
else
    echo "Executing: $DB2_HOME/instance/db2icrt -p $DB2_PORT -s ESE -u $FENCE_USER $INST_USER"
    $DB2_HOME/instance/db2icrt -p $DB2_PORT -s ESE -u $FENCE_USER $INST_USER
    rc=$?
    if [ "$rc" -ne 0 ]; then
       echo "Error: Unable to register DB2 engine instance. Return code: $rc"
       exit $rc
    fi
    echo "Instance $INST_USER built successfully."
fi

echo "=================================================================="
echo "Phase 3: Database Creation & Optimization Config (As TRIRIGA User)"
echo "=================================================================="

# CRITICAL CHANGE: Switching context explicitly to the TRIRIGA user account
su - $TRIRIGA_USER <<EOF
echo "Current Execution User: \$(whoami)"

echo "Sourcing DB2 Instance Profile to allow command access..."
# TRIRIGA user reads the db2profile located in the db2inst1 home directory
if [ -f "$BASE_HOME_DIR/$INST_USER/sqllib/db2profile" ]; then
   . $BASE_HOME_DIR/$INST_USER/sqllib/db2profile
else
   echo "Warning: db2profile not found in $BASE_HOME_DIR/$INST_USER/sqllib/. Attempting commands anyway."
fi

echo "Starting the instance via profile context if it is stopped..."
db2start
rc=\$?
if [ \$rc -ne 0 ] && [ \$rc -ne 1 ]; then
    echo "Error: Failed to activate engine instance context. Return code: \$rc"
    exit 1
fi

ok=0

echo "Creating DB2 Database ($DB2_DBNAME) using TRIRIGA guidelines..."
echo "Command: db2 create db $DB2_DBNAME ALIAS $DB2_DBNAME using codeset UTF-8 territory $TERRITORY pagesize 32 K"
db2 create db $DB2_DBNAME ALIAS $DB2_DBNAME using codeset UTF-8 territory $TERRITORY pagesize 32 K
if [ \$? -ne 0 ]; then
   echo "Fatal Error: Database instantiation failed."
   exit 1
fi

echo "Connecting to $DB2_DBNAME..."
db2 connect to $DB2_DBNAME
if [ \$? -ne 0 ]; then
   echo "Fatal Error: Connection dropped target database."
   exit 1
fi

echo "Configuring multi-byte character configuration layer (CODEUNITS32)..."
db2 update db cfg for $DB2_DBNAME using string_units CODEUNITS32
[ \$? -ne 0 ] && ok=\$?

echo "Granting administrative permissions to TRIRIGA access identities..."
db2 GRANT DBADM ON DATABASE TO USER $TRIRIGA_USER; [ \$? -ne 0 ] && ok=\$?
db2 GRANT SECADM ON DATABASE TO USER $TRIRIGA_USER; [ \$? -ne 0 ] && ok=\$?
db2 GRANT ACCESSCTRL ON DATABASE TO USER $TRIRIGA_USER; [ \$? -ne 0 ] && ok=\$?
db2 GRANT DATAACCESS ON DATABASE TO USER $TRIRIGA_USER; [ \$? -ne 0 ] && ok=\$?

echo "Binding performance packages..."
db2 bind '$DB2_HOME/bnd/db2clipk.bnd' collection NULLIDR1
[ \$? -ne 0 ] && ok=\$?

echo "Applying runtime memory manager parameter configurations..."
db2 update dbm cfg using RQRIOBLK 65535; [ \$? -ne 0 ] && ok=\$?
db2 update dbm cfg using AGENT_STACK_SZ 1024; [ \$? -ne 0 ] && ok=\$?
db2 update db cfg for $DB2_DBNAME using STMT_CONC OFF; [ \$? -ne 0 ] && ok=\$?

echo "Applying required TRIRIGA database storage parameters..."
db2 update db cfg for $DB2_DBNAME using LOGPRIMARY 23; [ \$? -ne 0 ] && ok=\$?
db2 update db cfg for $DB2_DBNAME using LOGFILSIZ 32768; [ \$? -ne 0 ] && ok=\$?
db2 update db cfg for $DB2_DBNAME using LOGSECOND 12; [ \$? -ne 0 ] && ok=\$?
db2 update db cfg for $DB2_DBNAME using LOGBUFSZ 8192; [ \$? -ne 0 ] && ok=\$?
db2 update db cfg for $DB2_DBNAME using LOCKTIMEOUT 30; [ \$? -ne 0 ] && ok=\$?
db2 update db cfg for $DB2_DBNAME using catalogcache_sz 2048; [ \$? -ne 0 ] && ok=\$?

db2 connect reset

echo "Cycling instance manager engine to finalize configurations..."
db2stop force
db2start

if [ \$ok -ne 0 ]; then
   echo "Configuration Warning: One or more underlying configurations failed."
   exit \$ok
fi

echo "Database $DB2_DBNAME successfully optimized by user \$(whoami)."
EOF

exit $?