-- =============================================================================
-- iRedMail vmail Database Schema
-- Based on official iRedMail 1.7.x schema
-- =============================================================================

-- Domain table
CREATE TABLE IF NOT EXISTS domain (
    domain VARCHAR(255) NOT NULL DEFAULT '',
    description TEXT,
    disclaimer TEXT,
    aliases INT(10) NOT NULL DEFAULT 0,
    mailboxes INT(10) NOT NULL DEFAULT 0,
    maillists INT(10) NOT NULL DEFAULT 0,
    maxquota BIGINT(20) NOT NULL DEFAULT 0,
    quota BIGINT(20) NOT NULL DEFAULT 0,
    transport VARCHAR(255) NOT NULL DEFAULT 'dovecot',
    backupmx TINYINT(1) NOT NULL DEFAULT 0,
    settings TEXT,
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    modified DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    expired DATETIME NOT NULL DEFAULT '9999-12-31 00:00:00',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (domain),
    INDEX (backupmx),
    INDEX (expired),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Domain admins
CREATE TABLE IF NOT EXISTS domain_admins (
    username VARCHAR(255) NOT NULL,
    domain VARCHAR(255) NOT NULL,
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (username, domain),
    INDEX (username),
    INDEX (domain),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Mailbox table (official iRedMail 1.7.x schema)
CREATE TABLE IF NOT EXISTS mailbox (
    username VARCHAR(255) NOT NULL DEFAULT '',
    password VARCHAR(255) NOT NULL DEFAULT '',
    name VARCHAR(255) NOT NULL DEFAULT '',
    language VARCHAR(5) NOT NULL DEFAULT 'en_US',
    first_name VARCHAR(255) NOT NULL DEFAULT '',
    last_name VARCHAR(255) NOT NULL DEFAULT '',
    mobile VARCHAR(255) NOT NULL DEFAULT '',
    telephone VARCHAR(255) NOT NULL DEFAULT '',
    recovery_email VARCHAR(255) NOT NULL DEFAULT '',
    birthday DATE NOT NULL DEFAULT '0001-01-01',
    mailboxformat VARCHAR(50) NOT NULL DEFAULT 'maildir',
    mailboxfolder VARCHAR(50) NOT NULL DEFAULT 'Maildir',
    storagebasedirectory VARCHAR(255) NOT NULL DEFAULT '/var/vmail',
    storagenode VARCHAR(255) NOT NULL DEFAULT 'vmail1',
    maildir VARCHAR(255) NOT NULL DEFAULT '',
    quota BIGINT(20) NOT NULL DEFAULT 0,
    domain VARCHAR(255) NOT NULL DEFAULT '',
    transport VARCHAR(255) NOT NULL DEFAULT '',
    department VARCHAR(255) NOT NULL DEFAULT '',
    `rank` VARCHAR(255) NOT NULL DEFAULT 'normal',
    employeeid VARCHAR(255) NOT NULL DEFAULT '',
    isadmin TINYINT(1) NOT NULL DEFAULT 0,
    isglobaladmin TINYINT(1) NOT NULL DEFAULT 0,
    enablesmtp TINYINT(1) NOT NULL DEFAULT 1,
    enablesmtpsecured TINYINT(1) NOT NULL DEFAULT 1,
    enablepop3 TINYINT(1) NOT NULL DEFAULT 1,
    enablepop3secured TINYINT(1) NOT NULL DEFAULT 1,
    enablepop3tls TINYINT(1) NOT NULL DEFAULT 1,
    enableimap TINYINT(1) NOT NULL DEFAULT 1,
    enableimapsecured TINYINT(1) NOT NULL DEFAULT 1,
    enableimaptls TINYINT(1) NOT NULL DEFAULT 1,
    enabledeliver TINYINT(1) NOT NULL DEFAULT 1,
    enablelda TINYINT(1) NOT NULL DEFAULT 1,
    enablemanagesieve TINYINT(1) NOT NULL DEFAULT 1,
    enablemanagesievesecured TINYINT(1) NOT NULL DEFAULT 1,
    enablesieve TINYINT(1) NOT NULL DEFAULT 1,
    enablesievesecured TINYINT(1) NOT NULL DEFAULT 1,
    enablesievetls TINYINT(1) NOT NULL DEFAULT 1,
    enableinternal TINYINT(1) NOT NULL DEFAULT 1,
    enabledoveadm TINYINT(1) NOT NULL DEFAULT 1,
    `enablelib-storage` TINYINT(1) NOT NULL DEFAULT 1,
    `enablequota-status` TINYINT(1) NOT NULL DEFAULT 1,
    `enableindexer-worker` TINYINT(1) NOT NULL DEFAULT 1,
    enablelmtp TINYINT(1) NOT NULL DEFAULT 1,
    enabledsync TINYINT(1) NOT NULL DEFAULT 1,
    enablesogo TINYINT(1) NOT NULL DEFAULT 1,
    enablesogowebmail CHAR(1) NOT NULL DEFAULT 'y',
    enablesogocalendar CHAR(1) NOT NULL DEFAULT 'y',
    enablesogoactivesync CHAR(1) NOT NULL DEFAULT 'y',
    allow_nets TEXT DEFAULT NULL,
    disclaimer TEXT,
    settings TEXT,
    passwordlastchange DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    modified DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    expired DATETIME NOT NULL DEFAULT '9999-12-31 00:00:00',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (username),
    INDEX (domain),
    INDEX (department),
    INDEX (employeeid),
    INDEX (isadmin),
    INDEX (isglobaladmin),
    INDEX (enablesmtp),
    INDEX (enablesmtpsecured),
    INDEX (enablepop3),
    INDEX (enablepop3secured),
    INDEX (enablepop3tls),
    INDEX (enableimap),
    INDEX (enableimapsecured),
    INDEX (enableimaptls),
    INDEX (enabledeliver),
    INDEX (enablelda),
    INDEX (enablemanagesieve),
    INDEX (enablemanagesievesecured),
    INDEX (enablesieve),
    INDEX (enablesievesecured),
    INDEX (enablesievetls),
    INDEX (enablelmtp),
    INDEX (enableinternal),
    INDEX (enabledoveadm),
    INDEX (`enablelib-storage`),
    INDEX (`enablequota-status`),
    INDEX (`enableindexer-worker`),
    INDEX (enabledsync),
    INDEX (enablesogo),
    INDEX (passwordlastchange),
    INDEX (expired),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Alias table
CREATE TABLE IF NOT EXISTS alias (
    address VARCHAR(255) NOT NULL DEFAULT '',
    name VARCHAR(255) NOT NULL DEFAULT '',
    accesspolicy VARCHAR(30) NOT NULL DEFAULT '',
    domain VARCHAR(255) NOT NULL DEFAULT '',
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    modified DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    expired DATETIME NOT NULL DEFAULT '9999-12-31 00:00:00',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (address),
    INDEX (domain),
    INDEX (expired),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Forwardings table
CREATE TABLE IF NOT EXISTS forwardings (
    id BIGINT(20) UNSIGNED AUTO_INCREMENT,
    address VARCHAR(255) NOT NULL DEFAULT '',
    forwarding VARCHAR(255) NOT NULL DEFAULT '',
    domain VARCHAR(255) NOT NULL DEFAULT '',
    dest_domain VARCHAR(255) NOT NULL DEFAULT '',
    is_list TINYINT(1) NOT NULL DEFAULT 0,
    is_forwarding TINYINT(1) NOT NULL DEFAULT 0,
    is_alias TINYINT(1) NOT NULL DEFAULT 0,
    is_mailbox TINYINT(1) NOT NULL DEFAULT 0,
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (id),
    UNIQUE KEY (address, forwarding),
    INDEX (domain),
    INDEX (dest_domain),
    INDEX (is_list),
    INDEX (is_forwarding),
    INDEX (is_alias),
    INDEX (is_mailbox),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Alias domain
CREATE TABLE IF NOT EXISTS alias_domain (
    alias_domain VARCHAR(255) NOT NULL DEFAULT '',
    target_domain VARCHAR(255) NOT NULL DEFAULT '',
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    modified DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (alias_domain),
    INDEX (target_domain),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Sender BCC
CREATE TABLE IF NOT EXISTS sender_bcc_domain (
    domain VARCHAR(255) NOT NULL DEFAULT '',
    bcc_address VARCHAR(255) NOT NULL DEFAULT '',
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    modified DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    expired DATETIME NOT NULL DEFAULT '9999-12-31 00:00:00',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (domain),
    INDEX (bcc_address),
    INDEX (expired),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS sender_bcc_user (
    username VARCHAR(255) NOT NULL DEFAULT '',
    bcc_address VARCHAR(255) NOT NULL DEFAULT '',
    domain VARCHAR(255) NOT NULL DEFAULT '',
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    modified DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    expired DATETIME NOT NULL DEFAULT '9999-12-31 00:00:00',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (username),
    INDEX (bcc_address),
    INDEX (domain),
    INDEX (expired),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Recipient BCC
CREATE TABLE IF NOT EXISTS recipient_bcc_domain (
    domain VARCHAR(255) NOT NULL DEFAULT '',
    bcc_address VARCHAR(255) NOT NULL DEFAULT '',
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    modified DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    expired DATETIME NOT NULL DEFAULT '9999-12-31 00:00:00',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (domain),
    INDEX (bcc_address),
    INDEX (expired),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

CREATE TABLE IF NOT EXISTS recipient_bcc_user (
    username VARCHAR(255) NOT NULL DEFAULT '',
    bcc_address VARCHAR(255) NOT NULL DEFAULT '',
    domain VARCHAR(255) NOT NULL DEFAULT '',
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    modified DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    expired DATETIME NOT NULL DEFAULT '9999-12-31 00:00:00',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (username),
    INDEX (bcc_address),
    INDEX (domain),
    INDEX (expired),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Used quota
CREATE TABLE IF NOT EXISTS used_quota (
    username VARCHAR(255) NOT NULL DEFAULT '',
    bytes BIGINT(20) NOT NULL DEFAULT 0,
    messages BIGINT(20) NOT NULL DEFAULT 0,
    domain VARCHAR(255) NOT NULL DEFAULT '',
    PRIMARY KEY (username),
    INDEX (domain),
    INDEX (bytes),
    INDEX (messages)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Admin table
CREATE TABLE IF NOT EXISTS admin (
    username VARCHAR(255) NOT NULL DEFAULT '',
    password VARCHAR(255) NOT NULL DEFAULT '',
    name VARCHAR(255) NOT NULL DEFAULT '',
    language VARCHAR(5) NOT NULL DEFAULT 'en_US',
    passwordlastchange DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    settings TEXT,
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    modified DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    expired DATETIME NOT NULL DEFAULT '9999-12-31 00:00:00',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (username),
    INDEX (passwordlastchange),
    INDEX (expired),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Log table (deprecated, kept for compatibility)
CREATE TABLE IF NOT EXISTS log (
    id BIGINT(20) UNSIGNED AUTO_INCREMENT,
    timestamp DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    admin VARCHAR(255) NOT NULL DEFAULT '',
    username VARCHAR(255) NOT NULL DEFAULT '',
    domain VARCHAR(255) NOT NULL DEFAULT '',
    event VARCHAR(255) NOT NULL DEFAULT '',
    loglevel VARCHAR(20) NOT NULL DEFAULT 'info',
    msg TEXT,
    ip VARCHAR(50) NOT NULL DEFAULT '',
    PRIMARY KEY (id),
    INDEX (timestamp),
    INDEX (admin),
    INDEX (username),
    INDEX (domain),
    INDEX (event),
    INDEX (loglevel)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Deleted mailboxes tracking
CREATE TABLE IF NOT EXISTS deleted_mailboxes (
    id BIGINT(20) UNSIGNED AUTO_INCREMENT,
    timestamp DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    username VARCHAR(255) NOT NULL DEFAULT '',
    domain VARCHAR(255) NOT NULL DEFAULT '',
    maildir VARCHAR(255) NOT NULL DEFAULT '',
    admin VARCHAR(255) NOT NULL DEFAULT '',
    bytes BIGINT(20) NOT NULL DEFAULT 0,
    messages BIGINT(20) NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    INDEX (timestamp),
    INDEX (username),
    INDEX (domain),
    INDEX (admin)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Mailing lists
CREATE TABLE IF NOT EXISTS maillists (
    id BIGINT(20) UNSIGNED AUTO_INCREMENT,
    address VARCHAR(255) NOT NULL DEFAULT '',
    domain VARCHAR(255) NOT NULL DEFAULT '',
    name VARCHAR(255) NOT NULL DEFAULT '',
    moderators TEXT,
    accesspolicy VARCHAR(30) NOT NULL DEFAULT 'public',
    maxmsgsize BIGINT(20) NOT NULL DEFAULT 0,
    subscription VARCHAR(20) NOT NULL DEFAULT 'normal',
    created DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    modified DATETIME NOT NULL DEFAULT '1970-01-01 01:01:01',
    expired DATETIME NOT NULL DEFAULT '9999-12-31 00:00:00',
    active TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (id),
    UNIQUE KEY (address),
    INDEX (domain),
    INDEX (expired),
    INDEX (active)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- Moderators table (for mailbox/alias moderation)
CREATE TABLE IF NOT EXISTS moderators (
    id BIGINT(20) UNSIGNED AUTO_INCREMENT,
    address VARCHAR(255) NOT NULL DEFAULT '',
    moderator VARCHAR(255) NOT NULL DEFAULT '',
    domain VARCHAR(255) NOT NULL DEFAULT '',
    dest_domain VARCHAR(255) NOT NULL DEFAULT '',
    PRIMARY KEY (id),
    UNIQUE KEY (address, moderator),
    INDEX (address),
    INDEX (moderator),
    INDEX (domain),
    INDEX (dest_domain)
) ENGINE=InnoDB CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
